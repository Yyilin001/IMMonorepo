# Direct room-log command-credit batching

This is an opt-in single-gateway optimization for the direct-room event-log
write path. It removes most of the serialized per-message updates to the
shard admission pool; it does not change message durability, authorization,
idempotency, or the command-window limit.

`shard_only` is **not** the deployment default. A clean, same-host
1,500-connection room-log A/B measured worse message and room-log P95 with
that mode; see [the benchmark](../09-capacity/direct-room-log-admission-mode-ab-2026-08-21.md).
Use the normal `room` mode with a batch size of `32` unless conducting a new,
controlled experiment.

## Preconditions

- IM_V2_DIRECT_FANOUT_MODE=room_log
- IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room or shard_only
- One gateway replica for the benchmark. Credits are process-local, so each
  replica may retain at most one partially unused batch per active shard.
- PostgreSQL remains healthy and is the only authority for admission.

`IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room` is the default and preserves the
per-room command window while batching the durable shard admission reserve.
`shard_only` is the direct-room-log-only experiment: the durable shard command
window becomes the command-capacity authority for ordinary direct messages,
and the per-room counter is no longer rewritten. It is rejected at startup
outside `room_log` mode and is not the default after the A/B regression.

Set IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=32 for the initial load
test. The accepted range is 1...128; 0 is the default and disables the
feature. Start at 32. A larger value reduces SQL further, but increases the
conservative unused quota after a process crash or a lease rollover.

## Ordered append micro-batch

`IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE` is a separate, default-off write
optimization. It coalesces up to 2...32 already-established, plain direct
messages for distinct rooms into one PostgreSQL transaction and one set-based
append statement. It requires `room_log` and a nonzero shard-credit batch
size. The batch staging queue is bounded by
`IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED`; it must never be made
unbounded to increase apparent throughput. For the measured 8-vCPU,
single-Gateway high-activity profile, use:

```
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE=32
IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS=2
```

The `32` cap has two independent 1,500-online / 900-msg/s A/B samples on
that host; see [the result](../09-capacity/direct-room-log-batch32-ab-2026-08-21.md).
For an unmeasured topology, start at 8 or 16 and use the verification sequence
below before raising it. A cap changes only batching efficiency, never the
durability boundary or ACK-before-commit rule.

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
and no larger than the bounded foreground staging queue, and the observation
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
reply marker, profile/capability mutation, a duplicate room in the batch, or
an existing operation transparently falls back to the ordinary transaction.
Each fallback has its own bounded foreground admission and outcome; one
fallback failure must not fail another request in the same staging batch.
No client-visible ACK is sent until the selected append batch commits. Set the
append batch size to `0` to roll it back without a schema or data change.

## Safety model

Before the gateway issues a local credit, it atomically increments the
command window counter by a bounded batch in PostgreSQL. The message
transaction then consumes an already charged credit and keeps the ordinary
pure admission reducer by presenting its effective local state.

- No request can exceed the durable command-window limit.
- `shard_only` does not weaken authorization: room locking, active membership,
  mute checks, direct-pair and user-policy revision locks, stranger quota, and
  Gateway user/device rate limits are still evaluated before an acceptance.
- The idle direct-room `room_admission.command_window_used` value remains
  unchanged. Do not use that per-room metric to judge direct room-log traffic;
  use the shard-admission and Gateway rate-limit metrics instead.
- A failed message transaction returns its local token while its durable
  charge remains reserved; this is conservative, never an over-admission.
- A crash, restart, or lease expiry can waste no more than the remaining
  active credits in one batch per (gateway process, shard, lease).
- Fan-out, plan, and outstanding-work counters are excluded. They retain the
  normal exact per-message reservation protocol.
- The feature applies only to fixed two-member direct rooms in room_log mode.
  Planner and group paths are unchanged.

Do not attempt to reclaim unused credits by decrementing the counter outside
the normal admission-window reset/lease-renewal protocol. The bounded loss is
the price paid to keep the durable limit authoritative under crashes.

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

For a controlled A/B run, reset the disposable message data and
pg_stat_statements, hold connections, message rate, payload size, and gateway
count constant. First compare append size `0` with 8, 16, and 32 at a 1--2ms
base delay. Then compare the fixed base profile with the adaptive profile
using identical base delay, batch size, high-delay threshold, and observation
window. Preserve the shard-credit size while doing this; otherwise two write
optimizations change at the same time. Record message p50/p95/p99, accepted
rate, `pg_stat_statements` calls/mean time for the append CTE, WAL bytes per
accepted fact, and database admission queue peaks.

The shard-admission update/query count should approach one reservation per 32
accepted direct-room-log commands (per shard), not one tail update per
message. Compare accepted rate and p95/p99 latency as well; this optimization
cannot remove the subsequent message/event/index/WAL work.

Do not infer append batching from delay settings or queue depth alone. A
high `preclassified_individual` value is expected during first-contact traffic;
for a high-activity steady-state profile, record the committed-request fraction
after bilateral conversations have been warmed. A low committed fraction means
the next optimisation is batch eligibility coverage, not a larger delay or a
larger PostgreSQL connection pool.

## Rollback

Set `IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room` and
`IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=0`, then restart the gateway.
No migration or data rollback is required. Already reserved durable credits
remain counted in the current command window and therefore only make the
rollback conservatively stricter until the ordinary window/lease reset. The
room-local counter resumes from its existing value for new messages; this is
why a rollback should occur at a controlled test-window boundary rather than
mid-window if exact per-room rate accounting is required.
