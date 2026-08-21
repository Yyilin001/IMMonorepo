# Hot direct-room command-credit rollout — 2026-08-22

## Scope

This rollout verifies the promoted-hot-room single-command path introduced in
`4fdbe649`. It is intentionally narrower than the normal high-online test:
100 Gateway connections send into 100 fixed, established direct rooms at a
requested 600 messages/second. Each room therefore crosses the four committed
messages in five seconds promotion threshold while the ordered append batcher
still dispatches same-room commands one at a time.

Common settings: one Gateway, `room_log`, normal room admission, shard credit
batch `32`, 128 B message payload, one in-flight message per connection,
room-log pull enabled, 60-second hold, zero sync pulls.

Before the run, the deployment was corrected to use the existing seeded
immutable load profile `loadtest-v12`. The previous `loadtest-v2` setting had
no corresponding durable `shard_admission_pools` rows, so fresh direct-room
creation was correctly rejected as `UNAVAILABLE`. This correction is part of
the benchmark precondition, not a performance optimization.

## Result

| Image / setting | ACKed messages | Client skips | Message P95 | Room-log P95 | Workload failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| `hot-direct-4fdbe649`, room credits `2` | 34,230 | 1,881 | 148 ms | 96 ms | 0 |
| `empty-direct-projection-9c8de4fb`, room credits `0` | 33,591 | 3,038 | 129 ms | 95 ms | 0 |
| `hot-direct-4fdbe649`, room credits `2` (repeat) | 31,609 | 4,526 | 146 ms | 99 ms | 0 |

## Disposable-data control run

The sequential rows above are not a valid latency comparison because each arm
grew the same room histories. A later run truncated only the disposable load
data (messages and derived state; accounts/direct rooms were retained), reset
`pg_stat_statements`, and kept `fsync=on`, `synchronous_commit=on`, and
`full_page_writes=on`.

| Arm | ACKed messages | Client skips | Message P95 | Room-log P95 | Workload failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| `empty-direct-projection-9c8de4fb`, room credits `0` | 35,118 | 942 | 130 ms | 36 ms | 0 |
| `hot-direct-4fdbe649`, room credits `2` | 35,488 | 897 | 136 ms | 37 ms | 0 |

The candidate acknowledged 1.1% more messages and skipped 4.8% fewer sends,
but message P95 was 4.6% higher. This does **not** justify enabling the room
credit path as a latency default. The Gateway in this control campaign already
had the existing independent-room append batch enabled; a subsequent run with
the same setting recorded 35,113 ACKs and 143 ms message P95, which is normal
short-run variation rather than evidence of a new batch benefit.

The first candidate run recorded 14,938 durable room-credit reservations,
29,876 reserved credits, and 29,830 committed-credit consumes. That proves
the promoted hot-room path was used for the intended direct writes, including
single-command FIFO dispatches.

## Interpretation

This is a correctness and write-amplification coverage success, but it is not
evidence of a stable latency improvement. The runs were sequential and each
room's durable room-log history grew between runs; room-log pull work and
cache state therefore differed. Candidate P95 did not improve in either
sample.

The next valid performance decision requires a disposable, identically seeded
campaign per arm (or an exact data reset), with PostgreSQL WAL-byte deltas,
`pg_stat_statements` append/update calls, foreground queue peak, and p50/P95/
p99 captured for both arms. The next code candidate also adds safe
same-room microbatch support; it needs its own clean A/B because the current
credit-only result cannot predict that workload. Until then the switch remains
a measured-safe candidate, not a default performance recommendation.

## Same-room microbatch follow-up — 2026-08-22

Commit `55dfdb2b` permits multiple already-established, plain direct sends for
the **same** room in one atomic CTE, while retaining FIFO room ownership,
operation-key idempotency, and the old individual fallback for any policy
mutation. This was tested separately from the 100-room workload above because
a normal direct room has exactly two members: two authenticated users sent to
each other with 32 client-side in-flight commands, requested 600 msg/s,
128 B payloads, room-log pulls enabled, and a 60-second hold. Each arm reset
only disposable message/derived-state data before it ran.

| Arm | ACKed messages | Client skips | Message P95 | Room-log P95 | Atomic CTE shape | Workload failures |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Existing `hot-direct-4fdbe649`, existing 20 ms adaptive profile | 6,511 | 29,750 | 683 ms | 661 ms | one command per same-room transaction | 0 |
| `55dfdb2b`, same 20 ms adaptive profile | 3,966 | 31,892 | 1,039 ms | 1,026 ms | 1,983 commits / 3,966 requests (2.0 req/commit) | 0 |
| `55dfdb2b`, A/B-only 1 ms base / 2 ms high-activity delay | 6,972 | 28,998 | 620 ms | 546 ms | 19 commits / 38 requests; 6,935 singleton dispatches | 0 |

The 20 ms result is an important **negative** result, not a regression to
hide. The direct pair reaches the batcher in two-request turns. Waiting 20 ms
does make those two writes atomic, but adds enough server-side queueing that
the 32 in-flight commands per sender back up to about one second. PostgreSQL
was not saturated: the candidate's canonical append CTE averaged 0.569 ms
(1,983 calls, 3,966 rows). The bottleneck was batch scheduling, not WAL or an
unindexed statement.

The 2 ms run restored and slightly improved end-to-end latency (ACK +7.1%,
message P95 -9.2% versus the existing-image run), but it nearly never formed
a multi-request batch across the public network. It therefore cannot justify
enabling same-room microbatching as a broad throughput claim. The next code
iteration must select the longer delay only when actual queue fill predicts
amortisation; a global arrivals-per-second threshold alone cannot distinguish
a broad fan-in workload from a two-member direct turn.

## Queue-fill threshold correction — 2026-08-22

The 20 ms long-delay mode is now guarded by 400 arrivals in one second rather
than 20. This is not an arbitrary larger number: a useful long-delay batch
needs at least eight requests, and `8 / 20 ms = 400 requests/s` is the minimum
arrival rate that predicts that fill. The configuration remains opt-in and
keeps the ordinary 2 ms interactive cap.

Two clean real-host runs validated both sides of the decision:

| Workload, candidate `55dfdb2b` | ACKed messages | Client skips | Message P95 | Room-log P95 | High-delay flushes | Atomic append result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| One direct room, two members, requested 600 msg/s | 7,082 | 29,024 | 615 ms | 546 ms | 0 | Mostly singletons; no artificial 20 ms queueing |
| 100 established direct rooms, 100 connections, requested 600 msg/s | 35,307 | 1,152 | 142 ms | 36 ms | 2,480 | 3,302 committed atomic batches for 34,824 requests (10.5 req/batch) |

For the distributed run, PostgreSQL's canonical append CTE executed 3,716
times for 35,238 rows, an observed 9.5 messages per SQL transaction. The
message P95 remains within the prior clean 100-room range (136--143 ms), while
the two-member room no longer enters long-delay mode. This proves the profile
selects the intended workload class; it does not claim that a single ordered
conversation can be made infinitely parallel.

## 1,000 msg/s read/write admission A/B — 2026-08-22

The 800 msg/s, 100-room workload is stable at 796 ACK/s with two in-flight
commands per connection. At requested 1,000 msg/s, PostgreSQL write admission
still had no queue or rejection, but room-log pulls began queueing behind the
12 reserved interactive-read permits. A read-disabled diagnostic improved ACK
from 53,526 to 57,379 and message P95 from 229 to 176 ms, establishing that
the next limit was foreground read competition rather than a canonical write
or WAL failure.

The production single-host reservation was then changed within the existing
32-permit isolated foreground pool, from append/control/read `16/4/12` to
`12/4/16`. It neither opens extra PostgreSQL connections nor changes
`fsync=on`, `synchronous_commit=on`, or `full_page_writes=on`.

| 100 connections, 100 direct rooms, 1,000 msg/s, 2 in-flight, room-log enabled | ACKed | Client skips | Message P95 | Room-log P95 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| `16/4/12` reservation | 53,526 | 6,226 | 229 ms | 193 ms | 0 |
| `12/4/16` reservation | 55,844 | 4,058 | 207 ms | 129 ms | 0 |

The read-biased reservation improved ACK by 4.3%, reduced client skips by
34.8%, reduced message P95 by 9.6%, and reduced room-log P95 by 33.2%. The
same run recorded 4,779 canonical append CTE calls for 55,817 rows (11.7
messages per transaction). This is a measured single-host improvement; it is
not a substitute for future conversation-affine database shards once the
canonical write lane itself becomes saturated.

## 1,200 msg/s room-credit batch-size A/B — 2026-08-22

The next clean distributed test exposed a separate source of write
amplification. With room credits enabled at the original size of two, each
promoted direct room acquired durable room-window capacity roughly once for
every two committed commands, even though the canonical append already
coalesced roughly ten messages per PostgreSQL transaction. The test host's
room command window is 100,000 commands, and the credit-pool implementation
already clamps a reservation to the durable remaining capacity. The candidate
therefore increased only the tested room-credit batch cap from `2` to `32`;
it preserves the same room lease fence, capacity authority, ordered append,
idempotency operation fence, and ACK-after-commit rule.

All rows used disposable-data reset, 100 established direct rooms, 100
connections, two in-flight commands per connection, requested 1,200 msg/s,
128 B payloads, room-log pulls enabled, and a 60-second hold. Commit
`6415efe5` also changes the PostgreSQL integration test to configure a batch
of 32 against a room with only two remaining commands, proving the durable
reservation is clamped and cannot oversell the room window.

| Room credit batch | ACKed | Client skips | Message P95 | Room-log P95 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| `2`, clean run 1 | 69,399 | 2,605 | 156 ms | 104 ms | 0 |
| `2`, clean run 2 | 67,621 | 4,080 | 166 ms | 104 ms | 0 |
| `32`, `6415efe5` | 69,701 | 2,004 | 134 ms | 99 ms | 0 |

The `32` run reduced the room-admission reservation CTE from about 31,447
calls to 2,100 (-93%). It durably reserved 67,200 room credits, committed
64,935, and retained 2,265 unused credits after the run. These credits are
already charged to PostgreSQL; they are a conservative, bounded availability
loss if the Gateway crashes, never an unaccounted capacity grant. There were
no capacity rejections. Relative to the better two-credit run, the candidate
raised ACK by 0.4%, reduced client skips by 23.1%, and reduced message P95 by
14.1%; relative to the two-credit median, the latency reduction is 16.8%.

The result validates this single-host write-amplification reduction at 1,200
msg/s. It does not make a per-room writer parallel: above this profile the
next observed pressure remains concurrent room-log reads and the physical
PostgreSQL commit/WAL path. A first 1,400-msg/s candidate run had an unstable
client arrival rate and is deliberately excluded from the capacity claim
until it is repeated with the same diagnostics.
