# 1,500 online direct room-log stability boundary (2026-08-21)

This records the post-batch-32 boundary on the single ARM64 8-vCPU / 16-GiB
test host. It is an end-to-end public-TLS result, not a production capacity
guarantee.

## Constant workload

- One Gateway, PostgreSQL 16, durable WAL (`fsync`, `synchronous_commit`, and
  `full_page_writes` enabled).
- 1,500 authenticated connections, 4,500 pre-opened direct rooms, four
  Gateway event loops, 128-byte plain messages, and one room-log pull after
  every message.
- Bounded direct append batches of 32 with a 2-ms normal and a 20-ms
  sustained-load delay; content review disabled.
- A run passes only when its 60-second steady phase has no workload failures
  and the bounded client queue completely drains within 10 seconds.

## Results

| Requested rate | Samples | Acknowledged | Drain | Message P95 / P99 | Room-log P95 / P99 | Decision |
| --- | ---: | ---: | --- | --- | --- | --- |
| 900 msg/s | 2 | 54,000 / 54,000 | 42 / 143 ms | 187 / 503, 187 / 481 ms | 50 / 109, 50 / 108 ms | Recommended sustained test rate |
| 950 msg/s | 2 | 57,000 / 57,000 | 37 / 71 ms | 285 / 525, 273 / 508 ms | 102 / 231, 102 / 127 ms | Highest verified no-backlog rate |
| 1,000 msg/s | 1 | 59,985 / 60,000 | Failed: 2 in-flight + 13 queued after 10 s | 229 / 618 ms | 87 / 111 ms | Not stable under the strict drain criterion |

The 950 and 1,000 runs use explicitly named scenarios in
`IMV2/load-scenarios/`. The 1,000 result is intentionally retained instead of
rounding the boundary upward: almost-complete acknowledgement is not the same
as a stable queue.

## Operational conclusion

For this host and workload, use 900 msg/s for steady latency investigations.
Treat 950 msg/s as the demonstrated upper throughput boundary, with less
latency headroom. Do not configure 1,000 msg/s as a stable target until the
next structural write-path or database-sharding change is measured.
