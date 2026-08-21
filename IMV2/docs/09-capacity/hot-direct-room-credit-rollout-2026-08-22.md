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
p99 captured for both arms. Until then the switch remains a measured-safe
candidate, not a default performance recommendation.
