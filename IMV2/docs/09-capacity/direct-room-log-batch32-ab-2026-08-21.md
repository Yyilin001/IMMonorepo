# Direct room-log batch-size 32 A/B (2026-08-21)

This is a same-host, sequential load-test result for the opt-in high-activity
profile. It supports the test-host configuration only; it is not a general
production capacity promise.

## Controlled workload

- ARM64 8-vCPU / 16-GiB host; one Gateway and PostgreSQL 16 with durable WAL
  (`fsync`, `synchronous_commit`, and `full_page_writes` enabled).
- 1,500 public-TLS Gateway connections, ramped at 100/s.
- 4,500 pre-opened direct rooms; 60 seconds at 900 message/s, 128-byte plain
  messages, and one room-log pull for each sent message.
- Direct room-log mode, bounded 2-ms normal / 20-ms sustained-load delay,
  shard command-credit batch size 32, content review disabled, and the same
  bounded event-cache profile in each run.

The runs are sequential on a long-lived test database, so PostgreSQL buffer
state is not asserted identical. Every Gateway process was restarted before
its run, and each run used a fresh 1,500-account credential set.

## Result

| Setting | 16-item cap | 32-item cap, sample 1 | 32-item cap, sample 2 |
| --- | ---: | ---: | ---: |
| Authenticated / failed | 1,500 / 0 | 1,500 / 0 | 1,500 / 0 |
| Message acknowledgements | 54,000 | 54,000 | 54,000 |
| Atomic append transactions | 4,140 | 2,698 | 2,692 |
| Committed requests / append | 12.9 | 19.9 | 19.9 |
| Message P50 / P95 / P99 | 66 / 272 / 509 ms | 73 / 187 / 503 ms | 72 / 187 / 481 ms |
| Room-log P50 / P95 / P99 | 23 / 99 / 126 ms | 21 / 50 / 109 ms | 20 / 50 / 108 ms |
| Workload failures | 0 | 0 | 0 |

The 32-item cap removes roughly 35% of append transactions while preserving
the same durable transaction and all-or-nothing batch cardinality checks.
It raises isolated-send batching potential only under the existing bounded
high-activity policy; the normal 2-ms path is unchanged.

## Decision and rollback

Use `IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE=32` in
`docker-compose.direct-room-log-adaptive-batching.yml` for this measured
single-Gateway test profile. Remove that compose overlay or override the value
to `16` (or `0`) and restart Gateway to roll back; neither data nor schema is
changed. Re-run the workload with a clean database before treating the result
as a production sizing input.
