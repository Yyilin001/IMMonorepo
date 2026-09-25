# Pure hybrid-group send benchmark — 2026-08-31

Status: historical benchmark for the 2026-08-31 build. Its workload and counters do not certify the current Actor-based runtime; see [current implementation evidence](../implementation-status.md).

## Scope

This benchmark isolates the accepted-send path for large hybrid groups. It is
not an end-to-end reader benchmark: room-log pulls and sync pulls are disabled
so that message admission, ordering and durable persistence can be profiled
without client read amplification.

- 1,000 authenticated TLS gateway connections
- 10 `large_group_hybrid` hot rooms, about 10,000 members per room
- two target rooms per account
- 128-byte plain messages, no mentions or attachments
- 30-second steady phase
- 16 room-ordered admission lanes
- Gateway: 4 vCPU / 8 GiB
- PostgreSQL: 8 vCPU / 16 GiB

Before the final boundary runs, old development load-test message artifacts
were truncated. This recovered the PostgreSQL data volume from 98% used to
82% used. A prior 9,000 msg/s attempt failed with `No space left on device` and
is excluded because it was an environment-capacity failure, not a throughput
result.

## Result

| Offered rate | Sent / acknowledged | Queue peak | Message P50 | P95 | P99 | Drain | Verdict |
|---:|---:|---:|---:|---:|---:|---:|---|
| 600 msg/s, old scalar baseline | 18,000 / 18,000 | 178 | 399 ms | 1,154 ms | 1,757 ms | — | pass |
| 600 msg/s, repeated-room batch | 18,000 / 18,000 | 5 | 12 ms | 29 ms | 32 ms | — | pass |
| 1,000 msg/s | 30,000 / 30,000 | 8 | 13 ms | 23 ms | 32 ms | — | pass |
| 1,500 msg/s | 45,000 / 45,000 | 11 | 15 ms | 24 ms | 32 ms | — | pass |
| 2,000 msg/s | 60,000 / 60,000 | 19 | 17 ms | 27 ms | 35 ms | — | pass |
| 3,000 msg/s | 90,000 / 90,000 | 44 | 20 ms | 33 ms | 43 ms | — | pass |
| 4,500 msg/s | 135,000 / 135,000 | 55 | 34 ms | 63 ms | 89 ms | — | pass |
| 6,000 msg/s, 8 lanes | 180,000 / 180,000 | 92 (Gateway) | 34 ms | 84 ms | 125 ms | — | pass |
| 8,000 msg/s, 16 lanes | 240,000 / 240,000 | 4 (client) | 52 ms | 124 ms | 188 ms | 263 ms | pass |
| **9,000 msg/s, 16 lanes** | **270,000 / 270,000** | **4 (client)** | **68 ms** | **178 ms** | **263 ms** | **198 ms** | **stable pass** |
| 10,000 msg/s, 16 lanes | 299,810 / 299,810 | 723 (client) | 191 ms | 658 ms | 2,301 ms | 2,676 ms | offered-rate failure |

At the original 600 msg/s comparison point, repeated-room set batching reduced
P50 by 33.3x, P95 by 39.8x and P99 by 54.9x. The current strict stable send-only
boundary is 9,000 msg/s. The 10,000 msg/s run eventually drained with no
application rejection, but exceeded the bounded scheduler queue contract and
therefore is not a steady-state pass.

## Resource boundary at 9,000 msg/s

During the 30-second phase:

- Gateway averaged about 3.41 of 4 CPU cores and peaked at 3.44 cores.
- PostgreSQL averaged about 5.10 of 8 CPU cores and peaked at 5.84 cores.
- PostgreSQL active sessions peaked at 14.
- only 10 room transactions could be in flight because the workload had 10 hot
  rooms and ordering is serialized per room.
- Gateway batch pending requests peaked at 222; the busiest lane peaked at 47.

The machines are not uniformly CPU-saturated. The boundary is a combination of
per-room serialization, shared admission-row locking, durable write work and
WAL/index amplification.

## PostgreSQL hotspots

The clean 9,000 msg/s run reset `pg_stat_statements` immediately beforehand.

| Operation | Calls / rows | Total execution | Mean per call | WAL |
|---|---:|---:|---:|---:|
| hybrid-group set persistence | 8,809 calls | 80.02 s | 9.084 ms | 853 MB |
| row-triggered group wake upsert | 270,000 rows | 27.98 s | 0.104 ms | 86 MB |
| authoritative group preflight | 8,809 calls / 269,988 rows | 15.70 s | 1.782 ms | 16 MB |
| room foreign-key checks | 1,071,747 rows | 9.17 s | 0.009 ms | negligible |
| shard admission reservation | 8,809 calls | 3.16 s | 0.359 ms | 1.1 MB |

At 10,000 msg/s, the persistence statement rose to 85.03 seconds and the shard
admission reservation rose sharply to 14.65 seconds despite only 6,151 larger
batches. The ten test rooms share four physical shard-admission rows, so
overlapping room transactions contend on those durable counters. This is the
clearest saturation cliff after the repeated-room batch optimization.

Each accepted hybrid-group message still creates or updates the following
canonical artifacts:

1. `messages`
2. `room_events`
3. terminal zero-target `fanout_plans`
4. `message_projection_states`
5. one row-triggered `group_event_wake_outbox` upsert
6. room/admission counters and the shared shard-admission counter

The set-based statement removes database round trips and coalesces mutable room
updates, but it intentionally does not remove these durable artifacts. This is
why latency improved by more than 30x at 600 msg/s while WAL per message remains
the next structural limit.

## Next optimization order

1. Replace the row-level hybrid-group wake trigger with a statement-level
   transition-table trigger, reducing a batch to one wake upsert per distinct
   room.
2. Move ordinary hybrid-group command capacity to the existing durable
   process-credit reservation model, or split shard admission into more
   independently locked buckets. Preserve lease generation and crash-safe
   accounting; do not merely cache the counter without a durable reservation.
3. Store the accepted event in the message row, as the direct room-log path
   already does, and stop duplicating the full accepted payload in
   `room_events` after readers support the representation.
4. Remove terminal zero-target fanout-plan rows from ordinary hybrid-group
   messages, retaining plans only for work that is actually enumerated or for
   explicit audit/control events.
5. Narrow `message_projection_states` to immutable references for revision 1,
   keeping separate state rows only when edit/withdrawal creates a later
   revision.

Steps 3–5 require a storage-contract migration and reader compatibility work.
They should be measured by WAL bytes per accepted message, not only latency.

## Interpretation boundary

This result proves the capacity of the group **send acceptance** path under ten
hot rooms. It does not prove 9,000 msg/s end-to-end delivery to active readers.
The next realistic group test must add room-log pulls, slow/fast reader mixes,
reconnect/catch-up traffic and a larger room-count distribution while keeping
the accepted-send rate constant.
