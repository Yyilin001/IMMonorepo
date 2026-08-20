# Direct room-log command-credit batching

This is an opt-in single-gateway optimization for the direct-room event-log
write path. It removes most of the serialized per-message updates to the
shard admission pool; it does not change message durability, authorization,
idempotency, or the command-window limit.

## Preconditions

- IM_V2_DIRECT_FANOUT_MODE=room_log
- IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=shard_only
- One gateway replica for the benchmark. Credits are process-local, so each
  replica may retain at most one partially unused batch per active shard.
- PostgreSQL remains healthy and is the only authority for admission.

`IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room` is the default and preserves the
legacy per-room command window. `shard_only` is the direct-room-log-only
optimization: the durable shard command window becomes the command-capacity
authority for ordinary direct messages, and the per-room counter is no longer
rewritten. It is rejected at startup outside `room_log` mode.

Set IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=32 for the initial load
test. The accepted range is 1...128; 0 is the default and disables the
feature. Start at 32. A larger value reduces SQL further, but increases the
conservative unused quota after a process crash or a lease rollover.

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

For a controlled A/B run, reset the disposable message data and
pg_stat_statements, hold connections, message rate, payload size, and gateway
count constant, then compare a setting of 0 with the same deployment at 32.

The shard-admission update/query count should approach one reservation per 32
accepted direct-room-log commands (per shard), not one tail update per
message. Compare accepted rate and p95/p99 latency as well; this optimization
cannot remove the subsequent message/event/index/WAL work.

## Rollback

Set `IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room` and
`IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=0`, then restart the gateway.
No migration or data rollback is required. Already reserved durable credits
remain counted in the current command window and therefore only make the
rollback conservatively stricter until the ordinary window/lease reset. The
room-local counter resumes from its existing value for new messages; this is
why a rollback should occur at a controlled test-window boundary rather than
mid-window if exact per-room rate accounting is required.
