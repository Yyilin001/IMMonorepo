# Pure Hybrid-group live benchmark — 2026-09-01

## Scope

This benchmark exercises the real live group path, not an ACK-only shortcut:

- 500 authenticated sender connections on Gateway 1;
- 500 authenticated passive connections on Gateway 2;
- 10 hot `large_group_hybrid` rooms, about 100 online members per room;
- two rooms assigned per account and one foreground room subscription;
- 128-byte messages for a 30-second steady phase;
- room-log cursors start at the current tail;
- Core NATS live delivery is enabled;
- the 100 ms recovery grace is enabled and a run fails on missing sequences,
  expired grace, recovery pulls, application errors, or an undrained client
  queue.

At 10,000 accepted group messages/s, the two Gateways apply 30 million
recipient events in 30 seconds. The recipient-event rate is therefore about
one million/s even though the input command rate is 10,000/s.

## Compared builds

`v38` is the statement-trigger and compact message-row baseline. `v40` keeps
the same message, authorization, room-log, NATS, recovery and socket semantics.
It changes only the durable group-wake bookkeeping:

1. an already-pending room wake is not rewritten by every later append;
2. a leased row is still replaced and revision-fenced by a newer commit;
3. the relay claims the row, then reads `rooms.room_sequence` in a second
   `READ COMMITTED` statement to obtain the authoritative committed
   high-watermark.

The second statement is essential. Reading the room counter in the original
claim statement can observe a snapshot from before a conflicting append that
the claim waited for, creating a lost-watermark race.

## End-to-end result

| Metric | v38 | v40 clean | Change |
|---|---:|---:|---:|
| sent / acknowledged | 300,000 / 300,000 | 300,000 / 300,000 | unchanged |
| applied live events, Gateway 1 | 15,000,000 | 15,000,000 | unchanged |
| applied live events, Gateway 2 | 15,000,000 | 15,000,000 | unchanged |
| live gaps / missing sequences | 0 / 0 | 0 / 0 | unchanged |
| expired recovery grace / pulls | 0 / 0 | 0 / 0 | unchanged |
| message P50 | 28 ms | 25 ms | -10.7% |
| message P95 | 63 ms | 58 ms | -7.9% |
| message P99 | 83 ms | 79 ms | -4.8% |
| client queue peak | 26 | 32 | both bounded |
| completion drain | 77 ms | 229 ms | both complete |

The v40 sender report is
`/opt/imv2-loadtest/reports/pure-group-v40-clean-sender-gw1-500-10000-r34-20260901.json`.
The passive report is
`/opt/imv2-loadtest/reports/pure-group-v40-clean-passive-gw2-500-10000-r34-20260901.json`.

An earlier report named `v40-wake-coalescing-*-r31` is excluded. Its remote
incremental build directory still contained a previously rejected local-first
self-echo experiment. The service was restored to v38, every source file in
the Linux builder was checksum-matched to the local tree, and the clean build
was then rebuilt and rerun.

## PostgreSQL result

| Statement | v38 | v40 clean | Interpretation |
|---|---:|---:|---|
| compact append total | 54.087 s | 54.312 s | unchanged dominant write path |
| compact append mean | 1.761 ms | 1.731 ms | -1.7% per SQL call |
| wake conflict total | 4.749 s | 4.551 s | -4.2% |
| wake conflict mean | 0.149 ms | 0.141 ms | -5.7% |
| authoritative claim reads | none | 10.6 ms total | negligible relay-only cost |
| full-database WAL sample | 239.4 MB | 252.2 MB | no proven improvement; checkpoint/FPI noise dominates this delta |

Only 717 of 32,396 v40 message-wake conflict statements changed the outbox
row. The other 97.8% found an already-pending row and avoided a new tuple
version. The conflict lookup and row lock still execute, which explains why
the SQL-time reduction is much smaller than the reduction in updated rows.

## Current hotspots

1. **Gateway 1 command and socket CPU.** During the active phase it used about
   3.4 of its 4 cores. Profiling attributes the work to Swift ARC, foreground
   writer scheduling, TLS/NIO writes, NATS encode/decode, event materialization
   and the send-command path.
2. **The compact PostgreSQL append.** It remains about 54 seconds of aggregate
   execution for the 30-second run. It serializes each hot room's sequence,
   inserts canonical message rows, maintains indexes and commits WAL.
3. **Recipient fan-out amplification.** Ten thousand input messages/s become
   roughly one million recipient-event applications/s. This is an intentional
   consequence of the tested active audience, not a load-generator artifact.
4. **Wake bookkeeping is now secondary.** Its 4.55 seconds are less than 8% of
   the append statement's aggregate time, so removing the remaining conflict
   probe cannot produce an order-of-magnitude gain.

## Why a 30x single-node gain is not available

At the same audience semantics, a 30x input target means about 300,000 group
messages/s and 30 million recipient-event applications/s. Linear projection
alone requires roughly 54 concurrent PostgreSQL query-seconds per wall second
for the current append SQL. That is not a literal CPU-core measurement—the
statement time also includes lock and I/O waits—but it is already far beyond
the execution budget of this single instance before WAL flush and background
maintenance. The current sender Gateway would similarly require dozens of
cores under linear scaling, and the live-event network volume grows linearly.

Consequently, the remaining 30x target is an architecture-scale target:

- partition rooms across multiple PostgreSQL owners so different rooms do not
  share one WAL stream or one room-store CPU budget;
- partition Gateway session/fan-out ownership and route each room publication
  only to nodes that own interested sessions;
- keep one canonical message body and transmit compact ordered deltas or
  availability hints to passive sessions;
- measure capacity in both accepted messages/s and recipient events/s.

These changes preserve the real path. Increasing batching until the load
generator queues work, suppressing delivery, reducing the active audience, or
skipping durable append work would improve a benchmark number but would not be
a valid 30x IM-system improvement.
