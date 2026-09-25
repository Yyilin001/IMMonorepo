# Direct room-log shard-only preflight experiment — 2026-08-21

> **历史归档。** `shard_only` 运行模式已于 2026-09-25 移除。该预检实验已被落地的分片路由合同取代，见
> [ADR-006 路由与迁移](../../00-foundation/ADR-006-routing-and-migration.md) 与
> [ADR-010 容量与灾备](../ADR-010-capacity-and-disaster-recovery.md)。
## Purpose

`V2DirectRoomLogAdmissionMode.shardOnly` had already skipped the
`room_admission` update for plain direct room-log messages, but its ordered
batch preflight still joined and took `FOR UPDATE` on that row.  That made the
mode pay a room-local read/lock cost without using the row in its successful
write path.

Revision `eef77420` adds a separate batch write-set for shard-only admission.
It retains the room lock, membership and mute checks, direct-pair and policy
revision locks, operation idempotency fence, and durable shard-credit
reservation.  The preflight does not materialize `room_admission`, and the
plain message CTE does not update it when `persistsRoomAdmission` is false.

This is deliberately an opt-in experiment.  The normal deployment remains
`IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE=room`.

## Safety invariants retained

- `rooms` remains `FOR UPDATE`, preserving FIFO room sequence allocation.
- Active membership, mute state, direct pair and policy revisions remain
  verified in the same source transaction.
- The `(sender_user_id, client_message_id)` operation fence remains durable
  and precedes preflight.
- The shard-credit actor only issues credits after PostgreSQL atomically
  charges `shard_admission_pools`; a process failure can waste a bounded
  reservation but cannot oversell a shard window.
- The accepted message row remains the durable canonical room event.

## Cloud A/B protocol

Both runs used the same 8 vCPU / 16 GiB single-host stack, public end-to-end
TLS, 1,500 authenticated connections, 100 connections/s ramp, 60-second
hold, 1,000 requested messages/s, 128-byte messages, three direct targets per
connection, no sync pull, and room-log pulls started at the tail.  Credentials
were refreshed after each Gateway restart.

| Result | Default `room` | Experimental `shard_only` | Change |
|---|---:|---:|---:|
| Message ACK | 66,342 | 67,682 | +2.0% |
| Message P95 / P99 | 423 / 1,045 ms | 288 / 481 ms | -32% / -54% |
| Room-log P95 / P99 | 432 / 853 ms | 303 / 461 ms | -30% / -46% |
| Heartbeat P95 / P99 | 352 / 1,337 ms | 158 / 389 ms | -55% / -71% |
| Client message skips | 495 | 26 | -95% |
| Workload failures | 627 | 214 | -66% |
| `room_event:SERVER_BUSY` | 260 | 214 | -18% |

The experiment's `room_admission` table statistics during its 1,000 msg/s
run changed from 1,145,945 to 1,148,516 primary-key index scans (+257), while
message inserts increased by 67,725 and `room_admission.n_tup_upd` did not
increase.  This confirms that the common plain-direct batch no longer reads or
updates the per-room admission row once per message; the residual scans are
from non-hot-path work and background activity.

Reports:

- `/tmp/imv2-mac-direct.TwmSdF/report-shard-only-eef77420-1500-1000-tail.json`
- `/tmp/imv2-mac-direct.TwmSdF/report-room-admission-9c8de4fb-1500-1000-tail.json`

## Why this is not a default-performance claim

The default run includes 367 `message:RATE_LIMITED:retryable` outcomes.  The
shard-only mode intentionally removes the durable *per-room* command window,
so those rejections disappear and shard-level capacity is the only command
limit.  That changes overload and anti-spam isolation for an unusually hot
direct conversation.  It is not an authorization bypass and does not weaken
ordering, membership or durable system-wide capacity, but it is a product
capacity-policy change.

Consequently the observed end-to-end win cannot be attributed solely to the
preflight SQL change, and `shard_only` must not replace `room` by default.
Before promotion, choose one of:

1. retain the durable per-room command window (no semantic change), accepting
   that its row is part of the transaction cost; or
2. specify a direct-message-only rate/abuse policy backed by a separate,
   durable quota authority and then evaluate shard-only against that approved
   policy.

The deployment has been restored to the default `room` mode after the A/B.
