# Direct room-log command-credit batching (retired)

> Historical record: the process-local room and shard command-credit pools, their metrics, and refill tests have been removed. This procedure no longer applies to the current server.

This is an opt-in single-gateway optimization for the direct-room event-log
write path. It removes most of the serialized per-message updates to the
shard admission pool; it does not change message durability, authorization,
idempotency, or the command-window limit.

The former `shard_only` experiment was removed after a clean, same-host
1,500-connection A/B measured worse message and room-log P95; see
[the historical benchmark](../09-capacity/direct-room-log-admission-mode-ab-2026-08-21.md).
Per-room admission is now the only direct room-log path.

The room-shard topology validation overlay exercises the same deployment
admission contract. The historical A/B remains research evidence, not a release gate.

## Preconditions

- Use the current room-log-only server; the retired fanout-mode selector must not be configured.
- Do not set the retired `IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE` variable; startup rejects it.
- One gateway replica for the benchmark. Credits are process-local, so each
  replica may retain at most one partially unused batch per active shard.
- PostgreSQL remains healthy and is the only authority for admission.

Per-room admission preserves the room command window while batching the durable
shard admission reserve.

Set IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=32 for the initial load
test. The accepted range is 1...128; 0 is the default and disables the
feature. Start at 32. A larger value reduces SQL further, but increases the
conservative unused quota after a process crash or a lease rollover.

## Preserving per-room admission while batching it

`IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE` is a separate, default-off
optimization for direct room-log admission. It removes the per-message
`room_admission` lock/update while retaining
the existing per-room command-window contract:

```
IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=32
IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE=16
```

The accepted range is `1...32`; it requires `room_log` and a nonzero
shard-credit batch. Room credits preserve the per-room limit.

For a room credit reservation, PostgreSQL atomically increments that room's
existing `room_admission.command_window_used` by at most the selected size,
fenced to the currently active shard lease and generation. The Gateway then
uses those already-charged credits locally. A rejected or rolled-back message
returns its local token, but never decrements the durable charge; a crash can
therefore only make the remainder of at most one batch per active
`(gateway, room, lease)` unavailable until the normal admission-window reset.
It cannot permit a command beyond the old room limit.

Start at `2` for the first deployment experiment. A direct room is much more
likely than a shared shard to have a low per-window command limit, and the
two-credit value is the only room reservation size exercised by the real
PostgreSQL integration test and the initial hot-room rollout. Larger values
require their own same-semantics A/B before use. Keep this default off until
that A/B has been recorded.

The Gateway does **not** reserve credits on a room's first request. A room is
locally promoted only after four successful ordinary direct appends in the
last five seconds. Cold and sparse conversations keep the original single
transaction path (`rooms` and `room_admission` are locked and updated
together), so enabling the switch cannot turn a broad fan-out of infrequent
conversations into one extra PostgreSQL reservation per room. Promotion is
based exclusively on committed canonical messages; denied, failed, duplicate,
or merely attempted sends cannot consume memory or make a room eligible. The
local promotion map is bounded to 8,192 rooms and drops inactive entries.

The same promoted-room path also covers a single command that the append
batcher must dispatch alone to preserve FIFO. It reuses the exact locked
preflight, policy mutation, canonical append, projection, and token-finalize
code used by a multi-room batch; it is not a weaker authorization path. This
matters because a genuinely hot two-person conversation is often the one case
that cannot put two of its own commands into one SQL batch.

## Ordered append micro-batch

`IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE` is a separate, default-off write
optimization. The runtime accepts `2...128` and coalesces already-established,
plain direct messages into bounded PostgreSQL transactions and set-based append
statements. The normal fairness pass first selects at most one command per
inactive room, then may use spare capacity for later commands from those same
hot rooms without allowing them to overtake an in-flight transaction. The
strict conditional fast-append statement accepts distinct rooms; a same-room
combination uses the complete ordered batch path or safely falls back. It
requires `room_log` and a nonzero shard-credit batch size. The batch staging
queue is always bounded. For compatibility it defaults to
`IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED`, but deployments with
measured burst traffic should size the request queue independently with
`IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS`. A database-work queue
counts operations while this queue counts messages; one atomic operation may
contain many messages, so treating those counts as interchangeable can shed a
bounded burst long before PostgreSQL is saturated. The explicit value must be
at least the append batch size and no more than 1,048,576. It must never be
made unbounded to increase apparent throughput. For the measured 8-vCPU,
single-Gateway high-activity profile, use:

```
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE=32
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS=2
```

Choose the pending bound from evidence: multiply the accepted message rate by
the longest transient execution stall the latency SLO is prepared to absorb,
then validate both memory and `append_batch_queue_wait_milliseconds_max`. For
example, 10,000 messages/s and a measured 277 ms stall require about 2,770
request slots; 4,096 is a bounded starting point, not a general default. A
larger value does not add steady-state throughput and must not be retained if
queue depth grows continuously or tail latency exceeds the SLO.

`IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT` is optional. It defaults
to the historic `min(8, IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT)` limit.
It may be raised only in a controlled A/B test and is bounded by the gateway's
total foreground-write admission capacity. It neither changes authorization
nor acknowledges before commit; it only lets more independent, already
eligible append transactions compete for the existing bounded database pool.
At each increment, require zero queue-overflow/rejections and compare P95,
PostgreSQL wait events, WAL pressure, and foreground-pool queue depth before
keeping the value.

The `32` setting has two independent 1,500-online / 900-msg/s A/B samples on
that host; see [the result](../09-capacity/direct-room-log-batch32-ab-2026-08-21.md).
For an unmeasured topology, start at 8 or 16 and use the verification sequence
below before raising it to 32, 64 or 128. The accepted runtime maximum is not a
recommendation: each increase expands transaction work, rollback scope and WAL
burst size and therefore requires its own A/B. A cap changes only batching
efficiency, never the durability boundary or ACK-before-commit rule.

The base delay is bounded to 1...25 ms. Keep the normal interactive base at
2 ms: a permanently larger value trades every isolated send's latency for
batch fill and should be used only as an explicitly measured experiment.

For a high-activity deployment, use the bounded adaptive policy rather than
applying a 20 ms delay to every send:

```
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS=2
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS=20
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS=20
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS=1000
```

The three `HIGH_ACTIVITY` values are all-or-nothing. The high delay must be
strictly greater than the base delay, the request threshold is at least two
and no larger than the bounded append staging queue, and the observation
window is 1...1,000 ms. Arrival measurement uses a process-local monotonic
clock and retains no more than the threshold number of samples. It controls
only a newly scheduled underfilled batch: it cannot reorder a room, extend a
timer beyond its selected cap, bypass a database permit, or acknowledge a
message before the atomic write commits. Clearing all three values restores
the exact fixed-delay behaviour without a migration.

The batcher takes one
foreground-write database admission immediately around each actual atomic
transaction, rather than consuming one admission permit for every request
waiting to form that batch. This preserves the normal database overload
backpressure while permitting one WAL commit to cover several requests.

### Fast-append cache working set

`IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES` bounds the durable-
fenced snapshots used by the one-statement conditional append. It defaults to
50,000 and accepts `1...1,048,576`. Size it for the number of active
`(room, sender)` pairs seen during the entry TTL, not for the connection count.
For example, 45,000 users sending in both directions can approach 90,000 keys;
use 131,072 for that controlled load profile:

```
IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES=131072
IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS=600
```

The TTL defaults to 600 seconds and accepts `1...3,600`. It must cover the
measured revisit interval for the active `(room, sender)` working set. A
60-second TTL is ineffective for a 90,000-key workload at 1,000 messages/s:
the average revisit is about 90 seconds, so most snapshots expire immediately
before their second use. Raising the TTL does not extend any authorization or
lease. The cache does **not** store room or timeline cursors. PostgreSQL locks
the current room row and allocates the next sequence from that row; the cached
membership, direct-pair, user-policy, profile/capacity and shard-lease facts are
accepted only when their durable revisions still match. A stale hint can only
make the conditional statement affect no row and fall back.

The cache is a process-local O(1) LRU and never authorizes a write by itself.
Every fast append remains fenced by the durable current room row, membership,
direct-pair/user-policy revisions, active profiles, room admission and shard
lease in PostgreSQL. Room/timeline sequence is allocated while holding the room
row lock rather than compared to a cache snapshot. Capacity or TTL eviction only
causes a safe fallback to the complete transaction. Do not raise the bound blindly:
compare entry count, capacity removals, process RSS, fast-append hit rate, and
fallback count after warm-up.

## Control-plane admission isolation

`open_direct_room` uses the separate `foreground_control_write` admission
lane. It is a durable mutation, but it is not the hot path for messages in an
already-open conversation. Its reservation is deliberately small and shares
the same physical PostgreSQL foreground pool with message appends and room-log
reads; it does **not** create extra database connections.

For the 8-vCPU benchmark host, configure the 32 foreground permits as 16
message writes, 4 control writes, and 12 interactive reads. The direct append
batcher itself is capped at 8 concurrent transactions, so reserving more than
16 message permits did not improve that hot path but could starve room-log
pulls:

```
IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT=16
IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT=4
IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT=12
IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_MAX_QUEUED=1152
```

This makes a direct-room creation surge wait in its own bounded queue instead
of stealing the message reservation. It does not promise that cold-start room
creation is fast; measure that phase separately, then begin the steady
message workload only after warmup completes.

A request with media, mentions,
reply/forward state, content review, stranger quota consumption, an initial
reply marker, profile/capability mutation or an existing operation transparently
falls back to the complete transaction. A cache-cold or revision-mismatched
plain message follows the same rule. Multiple commands for one room do not use
the conditional set append, because that statement advances one cursor per
room; they fall back to ordered one-command appends before a partial commit.
Each fallback has its own bounded foreground admission and outcome; one
fallback failure must not fail another request in the same staging batch.
No client-visible ACK is sent until the selected append batch commits. Set the
append batch size to `0` to roll it back without a schema or data change.

## Safety model

Before the gateway issues a local credit, it atomically increments the
command window counter by a bounded batch in PostgreSQL. The message
transaction then consumes an already charged credit and keeps the ordinary
pure admission reducer by presenting its effective local state.

Only a revision-fenced warm append may request such a credit, and it must do
so **before** opening its canonical message transaction. Cold, rich and cache-
mismatch paths perform an exact conditional shard increment as the final SQL
statement in their canonical transaction. Do not move a credit-pool refill
behind room or policy locks: the refill uses an independently committed SQL
statement and borrowing it from the same bounded foreground pool can make all
outer transactions wait for connections they already hold.

- No request can exceed the durable command-window limit.
- Authorization still requires room locking, active membership,
  mute checks, direct-pair and user-policy revision locks, stranger quota, and
  Gateway user/device rate limits are still evaluated before an acceptance.
- The per-room `room_admission.command_window_used` counter is authoritative
  for direct room-log traffic, including cold and rich sends.
- With room credits enabled, the per-room counter is
  still authoritative and therefore advances by each durable reservation,
  rather than by each ACK. It may be ahead of the accepted-message count by
  the local unused remainder; use it for enforcement, not exact analytics.
- A failed message transaction returns its local token while its durable
  charge remains reserved; this is conservative, never an over-admission.
- A crash, restart, or lease expiry can waste no more than the remaining
  active credits in one batch per (gateway process, shard, lease).
- Fan-out, plan, and outstanding-work counters are excluded. They retain the
  normal exact per-message reservation protocol.
- The feature applies only to fixed two-member direct rooms in room_log mode.
  Planner and group paths are unchanged.
- Batch issue/commit/release methods cross each process-local actor once per
  bounded warm micro-batch and always outside the PostgreSQL transaction. An
  implementation that loops `await acquire(...)` once per message—or performs
  any credit acquire while holding a database transaction—recreates a serial-
  executor/connection-pool backlog and is not equivalent to this design.

Do not attempt to reclaim unused credits by decrementing the counter outside
the normal admission-window reset/lease-renewal protocol. The bounded loss is
the price paid to keep the durable limit authoritative under crashes.

## Capacity-profile consistency

The environment is not the command-window authority after a shard admission
pool has been issued. The limits persisted in
`shard_admission_pools(room_shard_id, capacity_profile_id)` are authoritative,
and a capacity-profile identifier is immutable. Raising
`IM_V2_MAX_COMMANDS_PER_WINDOW` while reusing the old
`IM_V2_CAPACITY_PROFILE_ID` does not enlarge an existing durable window.

Gateway startup verifies every existing pool for its configured profile ID
against the configured command, fan-out, outstanding-unit, and outstanding-
plan limits. Any mismatch fails readiness before the TLS listener starts.
Treat that failure as a deployment/configuration error; never bypass it or
reset a production counter in place.

To change a limit, issue a new profile ID and new shard leases, migrate room
profile IDs and their `room_admission` fences atomically through the control
plane, verify that no migrated room still references the old fence, and only
then start Gateways configured for the new profile. A disposable performance
environment may reset its command-window counters as part of that explicit
migration, but the reset and all before/after row-count assertions must be in
the same transaction. Keep the old pools until rollback is no longer needed.

## Verification

Scrape the loopback /metrics endpoint. When enabled, observe:

- im_v2_shard_admission_command_credits (available): unused local credits; it
  should remain bounded by active shards times batch size.
- im_v2_shard_admission_command_credit_reservations_total and
  im_v2_shard_admission_command_credits_reserved_total: durable SQL batching
  is active.
- im_v2_shard_admission_command_credits_committed_total: accepted messages
  that consumed credits.
- im_v2_shard_admission_command_credit_rejections_total: capacity-window
  rejections. Any unexpected rise requires stopping the load test and
  verifying the configured lease/profile capacity.
- im_v2_room_admission_command_credit_hot_rooms: rooms that have passed the
  committed-message promotion threshold. In a sparse-online test this should
  remain near zero; a nonzero room-credit reservation count with this gauge at
  zero is a defect.
- im_v2_direct_room_log_append_atomic_batches_total and
  im_v2_direct_room_log_append_atomic_requests_total: whether Gateway staging
  produces real set-based message appends. `committed` is the only outcome
  that reduced PostgreSQL append transactions. `preclassified_individual`
  means a request safely used the ordinary path (for example a cold or
  first-reply direct-policy cache entry) without making unrelated established
  conversations abandon their atomic batch. `shape_fallback` means a durable
  revision or preflight check declined an otherwise eligible subset; it must
  remain low after a steady-state warm-up. These counters are diagnostics,
  not permission decisions.
- im_v2_direct_room_log_fast_append_entries and
  im_v2_direct_room_log_fast_append_removals_total: verify that the configured
  cache covers the measured active `(room, sender)` working set. A continuously
  rising `reason="capacity"` counter during a steady hold means cache churn.
- im_v2_direct_room_log_fast_append_lookups_total and
  im_v2_direct_room_log_fast_append_requests_total: compare cache hit rate and
  committed/fallback fractions. A cache hit is only a candidate; PostgreSQL's
  revision-fenced conditional statement remains the authority.

For a controlled A/B run, reset the disposable message data and
pg_stat_statements, hold connections, message rate, payload size, and gateway
count constant. First compare append size `0` with 8, 16, and 32 at a 1--2ms
base delay. Then compare the fixed base profile with the adaptive profile
using identical base delay, batch size, high-delay threshold, and observation
window. Preserve the shard-credit size while doing this; otherwise two write
optimizations change at the same time. Record message p50/p95/p99, accepted
rate, `pg_stat_statements` calls/mean time for the append CTE, WAL bytes per
accepted fact, and database admission queue peaks.

The shard-admission update/query count should approach one reservation per
configured credit batch of accepted direct-room-log commands (per shard), not one tail update per
message. Compare accepted rate and p95/p99 latency as well; this optimization
cannot remove the subsequent message/event/index/WAL work.

With the room-credit switch enabled, `room_admission` updates for **promoted
hot** direct conversations should similarly approach one reservation per
configured credit batch accepted commands per active room/lease. Cold rooms intentionally remain at
one update per accepted command. Verify the actual reservation count from
PostgreSQL statistics or a controlled `pg_stat_statements` sample; do not
infer it only from local process metrics.

## 2026-08-22 initial hot-room rollout result

See the complete [rollout record](../09-capacity/hot-direct-room-credit-rollout-2026-08-22.md).

The first end-to-end rollout used a single Gateway, 100 established direct
rooms, 600 requested messages/second, one fixed target per connection, 128 B
payloads, 60-second holds, and room-credit batch size `2`. The candidate
accepted 34,230 messages with zero workload failures; 29,830 committed
messages used room credits, while the remainder stayed on the normal path
during warm-up or after a local heat entry expired.

This was a correctness and coverage result, not a conclusive latency win. A
same-host baseline accepted 33,591 messages, but candidate and baseline runs
were sequential and room-log history grew between them. The candidate message
P95 was 148 ms versus baseline 129 ms, and a candidate repeat was 146 ms.
Do not claim a stable P95 improvement from these samples. Reset the
disposable load data (or use a fresh, identically seeded campaign) before
making a production latency decision; retain the three reports with the
deployment record.

Do not infer append batching from delay settings or queue depth alone. A
high `preclassified_individual` value is expected during first-contact traffic;
for a high-activity steady-state profile, record the committed-request fraction
after bilateral conversations have been warmed. A low committed fraction means
the next optimisation is batch eligibility coverage, not a larger delay or a
larger PostgreSQL connection pool.

## 2026-08-27 R29 sustained-gradient result

R29 removed the remaining per-message shard-credit actor entry from an already
coalesced append batch, changed the fast cache to stable revision facts only,
and allocated sequences from the locked PostgreSQL room row. A 50,000-online,
single-Gateway gradient from 500 through 5,000 msg/s completed with 2,475,000
ACKs for 2,475,000 scheduled messages, zero workload failures/rejections and a
fully drained queue. Message P95 across the five load partitions was 212--216
ms and P99 was 279--285 ms. The full topology, server/database metrics,
comparison limits and excluded workloads are recorded in
[the R29 capacity report](../09-capacity/direct-room-log-50000-gradient-r29-2026-08-27.md).

This is not a general production SLO: it used one Gateway, disabled content
review, plain direct messages, no explicit room-log pull QPS and 90-second rate
steps. Keep explicit pull, mixed message shapes, multi-Gateway credit waste,
lease rollover and long soak as separate release gates.

## 50k 梯度 A/B 前置校验

长时间容量测试在建立连接前必须同时验证以下条件；任一不满足都应 fail fast，不能等到 50,000
连接建立后再把围栏失败误判为性能回退：

1. 所有 access token 的最早到期时间晚于预计测试结束时间至少 2 分钟。Gateway 会在后续命令中
   继续执行 session expiry fence；“认证时尚未过期”不足以覆盖整轮测试。
2. `shard_admission_pools.valid_until` 覆盖预计结束时间加 30 分钟，且每个 load shard 的
   `command_window_limit - command_window_used` 大于该分片预计消息数并保留 credit batch 浪费余量。
3. 记录 `messages` 的行数、heap/index 总大小、`pg_stat_bgwriter` 与上次 checkpoint 时间。A/B
   必须从相同数据快照或明确清理过的 disposable 状态开始，并让 checkpoint 相位一致。不能只记录
   “测试窗口内发生过 checkpoint”：应分别记录测试开始时 checkpoint 是否正在进行、最近一次开始/完成
   时间、完成耗时和测试窗口内的 WAL/FPI 增量。若一轮在 checkpoint 外、另一轮在 checkpoint 内，
   该结果只能用于诊断，不能用于代码 A/B。
4. 监控必须采集精确指标名
   `im_v2_direct_room_log_append_batch_in_flight` 与
   `im_v2_direct_room_log_append_batch_execution_milliseconds_max`，同时记录 pending、queue wait、
   PostgreSQL CPU/active/lock/IO wait、WAL 增量和 checkpoint 日志。

2026-08-27 的受控 A/B 中，共享前台帧版本在相同清库与 checkpoint 条件下完成 2,475,000 / 2,475,000
ACK、0 failure；控制组出现 2,451 次 `SERVER_BUSY`。完整证据见
[R34 50,000 在线共享帧 A/B](../09-capacity/direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md)。

当 `checkpoint_timeout=30min` 且 `checkpoint_completion_target=0.9` 时，一次定时 checkpoint 的写入可被
摊到约 27 分钟；持续脏页负载下，这并不代表存在 30 分钟的无 checkpoint 稳定窗口。2026-08-28 的
历史数据复测在 4,500 msg/s 先出现 WAL/FPI、backend buffer 与 append queue 突刺，而非 CPU、内存、
连接或锁等待耗尽。后续容量试验必须使用 `scripts/preflight_v2_postgres_load_test.sh` 和前后 profile，
并按 [R36 checkpoint 诊断报告](../09-capacity/direct-room-log-50000-checkpoint-r36-2026-08-28.md)
区分连接容量、checkpoint 外吞吐和 checkpoint 内稳态吞吐。

## Rollback

Set `IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE=0` and, if required,
`IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=0`, then restart the gateway.
No migration or data rollback is required. Already reserved durable credits
remain counted in the current command window and therefore only make the
rollback conservatively stricter until the ordinary window/lease reset. The
room-local counter resumes from its existing value for new messages; this is
why a rollback should occur at a controlled test-window boundary rather than
mid-window if exact per-room rate accounting is required.
