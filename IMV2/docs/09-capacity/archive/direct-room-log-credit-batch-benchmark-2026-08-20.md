# Direct room-log shard-credit batch benchmark (2026-08-20)

> **历史归档。** 该批次实验已由
> [hot direct room credit 灰度记录](../hot-direct-room-credit-rollout-2026-08-22.md)
> 取代，后者是 [command-credit runbook](../../10-operations/direct-room-log-command-credit-runbook.md) 引用的当前依据。
This is a controlled, disposable-environment experiment. It validates the
admission-credit safety and SQL reduction of the direct room-log path; it is
not a production capacity promise.

## Change under test

`IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE=32` is enabled only together
with `IM_V2_DIRECT_FANOUT_MODE=room_log`.

Before issuing a process-local credit, the gateway atomically reserves a
bounded command-window batch in `shard_admission_pools`. A message transaction
then consumes one already-reserved credit. A failed transaction returns its
local credit; a process failure can only leave the unconsumed remainder of one
batch charged until the ordinary window/lease reset. It cannot over-admit a
shard and does not alter `fsync`, `synchronous_commit`, message idempotency,
membership checks, or room-event durability.

## Workload

- One ARM64 8-vCPU / 16-GiB Gateway + PostgreSQL host.
- 1,500 fresh disposable users, public TLS, 100 connections/s ramp.
- The `high-active-direct-1500-600-v1` scenario: symmetric direct peers,
  600 message/s and 600 room-log reads/s for 60 seconds.
- Content review disabled; `fsync=on`, `synchronous_commit=on`,
  `full_page_writes=on` in both runs.
- Each A/B arm used newly created test users so room cursors did not replay
  old event history. This avoids a history-read bias, but means the arms are
  not byte-for-byte disk-cache-identical.

## Results

| Metric | Batch 0 | Batch 32 | Interpretation |
| --- | ---: | ---: | --- |
| Authenticated / failures | 1,500 / 0 | 1,500 / 0 | Connection path unchanged. |
| Message ACK | 30,517 | 30,881 | Both runs sustained the requested load; this difference is normal ramp/scheduling noise. |
| Message ACK P95 | 485 ms | 477 ms | Small improvement, not enough to claim a new capacity tier. |
| Room-log pull P95 | 296 ms | 347 ms | Regressed within this short run; do not claim a read-latency gain. |
| Workload failures | 0 | 0 | No retryable overload or correctness failure. |
| Shard admission SQL calls | 30,517 | 761 | Batch arm reduced this write to about 31.8 messages per reservation. |

The batch arm exported 24,213 committed credits, 24,352 reserved credits, and
761 durable reservations while sampled during the run. The small difference
between reserved and committed credits is bounded, conservative headroom from
active batches; it is expected and is not a lost message.

## Steady-state regression command

`direct-1500-steady-900.json` separates the one-time connection/direct-room
warmup from the hot message phase. It is the correct follow-up workload when
testing the durable message path at 1,500 connected devices: the generator
waits until all 4,500 direct-room opens have completed, then runs exactly 60
seconds at 900 sends/s and 900 room-log reads/s. This prevents control-plane
room creation from being mistaken for a steady messaging capacity limit.

## WAL and group-commit observations

The batch-0 profile recorded 39,305 WAL writes and 38,061 WAL syncs during its
test window. The message commit CTE and the locked-room acceptance CTE remained
the two highest-cost statements, each about 1.5 ms mean execution time. Their
durable room/admission/message/event work remains per message, so removing the
shard counter cannot yield an order-of-magnitude result.

An additional 100-microsecond `commit_delay` / 10-sibling experiment was run
with `fsync=on` and `synchronous_commit=on`. It was worse in the same scenario
(message P95 509 ms, room-log P95 370 ms), so it was reset to PostgreSQL's
defaults (`commit_delay=0`, `commit_siblings=5`) and is **not** deployed.

WAL-byte totals should not be compared directly across these two short arms:
the first post-checkpoint writes generated substantially more full-page images.
Use a restored snapshot plus multiple warm repetitions for a formal WAL
bytes/message comparison.

## Conclusion

Keep batch size 32 for the single-gateway direct room-log benchmark because it
removes a verified redundant shard-counter write without weakening durability.
It is a supporting optimization, not the root throughput solution. The next
structural target is to reduce the mandatory per-message room/admission and
message/event transaction work, while preserving durable idempotency and
revision-fenced authorization.
