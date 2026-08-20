# Direct 1,500 steady 900 admission-isolation benchmark (2026-08-21)

This is a disposable single-host experiment, not a production capacity
commitment. It uses public TLS from a Mac load generator to one 8-vCPU / 16
GiB ARM64 Gateway/PostgreSQL host, with `fsync=on` and
`synchronous_commit=on`.

## Workload and safety boundary

The scenario is
[`direct-1500-steady-900.json`](../../load-scenarios/direct-1500-steady-900.json).
It authenticates 1,500 fresh disposable users, opens three symmetric direct
rooms per user, waits for all 4,500 open operations to succeed, then runs 60
seconds at 900 sends/s and 900 room-log pulls/s. This separation matters:
room creation is control-plane work and must not be treated as a steady send
throughput result.

The Gateway runs the direct append batcher and the three-lane admission split:

| Lane | Permits | Purpose |
| --- | ---: | --- |
| `foreground_write` | 16 | durable message acceptance |
| `foreground_control_write` | 4 | `open_direct_room` |
| `interactive_read` | 12 | room-log pulls |

All 32 permits share the existing physical foreground PostgreSQL pool. This
is admission isolation, not an increase in connection count or a durability
relaxation.

## Results

| Run | Per-device send limit | ACK / 60 s | Actual ACK/s | Message P95 | Room-log P95 | Workload failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fb52e78b` r2 | 1 | 32,461 | 541 | 517 ms | 308 ms | 0 |
| `fb52e78b` r4 | 2 | 29,356 | 489 | 2,568 ms | 1,510 ms | 0 |

Both runs authenticated all 1,500 clients and had no admission queue-full or
timeout rejection. The control-write queue also had no rejection. The r2
PostgreSQL message append CTE executed 32,646 times at 1.436 ms mean execution
time; that durable write, its locked-room authorization companion, indexes,
and WAL flush remain the primary server cost.

The generator deliberately reports skipped sends when a weighted active
device has reached its configured in-flight bound. At the requested 900
sends/s, r2 skipped 21,348 sends. Raising that bound from one to two did **not**
recover the rate: it increased end-to-end queueing and reduced completed ACKs.
Keep the bound at one for the representative workload. A raw maximum-throughput
test needs a separate, uniformly distributed workload; it must not be used to
claim the representative high-activity capacity.

## What the result proves

- The new control lane prevents the 4,500 direct-room warmup writes from
  stealing the message reservation.
- Rebalancing from 20/4/8 to 16/4/12 removes the prior room-log
  `SERVER_BUSY` failures under this mixed workload.
- The current single-host representative steady limit is below the requested
  900 sends/s plus 900 reads/s. It is approximately 540 acknowledged sends/s
  at the measured latency envelope, not 900 sends/s.

## Next structural target

Further queue enlargement would hide overload as latency and is not a fix.
The next throughput improvement must reduce work per accepted message:

1. fuse/reduce the locked-room authorization pre-read with the append path
   where the transaction already holds the required room fence;
2. keep the canonical message append synchronous, but move reconstructible
   projection/index effects behind bounded durable batches; and
3. profile a uniformly distributed ceiling workload separately from this
   weighted user-behaviour scenario.
