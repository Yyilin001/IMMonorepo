# Direct room-log tail-latency A/B — 2026-08-26

> **历史归档。** 该尾延迟 A/B 已被次日的 [R29 梯度记录](../direct-room-log-50000-gradient-r29-2026-08-27.md)
> 与 [R34 共享帧 A/B](../direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md) 取代。
## Scope

This run validates the process-local finalization and fast-append cache changes
under the existing single-Gateway/single-PostgreSQL topology. It is not a
multi-node capacity claim.

- 45,000 authenticated TLS connections
- two active direct rooms per account
- 1,000 scheduled messages/s for 180 seconds
- one room-log pull after each accepted message
- 128-byte message body
- nine load-generator partitions on the isolated 4-vCPU load host
- Gateway: 4 vCPU / 8 GiB
- PostgreSQL: 8 vCPU / 16 GiB host, 8 GiB container limit

The r1 and r2 runs reused the same 45,000 accounts in the same order and did
not clear PostgreSQL between runs. Both began with a cold Gateway process-local
cache. This makes r1 to r2 the strict implementation comparison. The older r5b
run is retained as the pre-change reference.

## Result

| Metric | r5b reference | r1 regression | r2 final |
| --- | ---: | ---: | ---: |
| Connections authenticated | 45,000 | 45,000 | 45,000 |
| Messages scheduled | 179,991 | 179,991 | 179,991 |
| Messages acknowledged | 179,991 | 179,430 | 179,980 |
| Workload failures | 0 | 561 | 11 |
| Message P50, partition range | 24–32 ms | 47–77 ms | 25–39 ms |
| Message P95, partition range | 49–64 ms | 1,311–1,346 ms | 33–48 ms |
| Message P99, partition range | 468–496 ms | 1,644–1,672 ms | 53–73 ms |
| Message maximum | 1,284 ms | 7,083 ms | 1,244 ms |
| Room-log P95, partition range | 4–6 ms | 6–8 ms | 3–5 ms |
| Room-log P99, partition range | 16–21 ms | 821–924 ms | 6–9 ms |
| Gateway steady CPU, average | 146.04% | 239.83% | 139.85% |
| PostgreSQL steady CPU, average | 157.32% | 322.63% | 162.46% |
| Append queue wait, steady maximum | 481 ms | 1,596 ms | 77 ms |
| Append execution, steady maximum | 714 ms | 539 ms before drain | 93 ms |

Relative to r5b, r2 reduced the per-partition message P99 range by about
85%–89% and P95 by about 25%–33%. Median latency is approximately unchanged to
7 ms slower depending on the partition. Gateway average CPU fell by about 4%;
PostgreSQL average CPU increased by about 3%, which is within the observed run
variation and confirms that the tail reduction came primarily from removing
Gateway scheduling amplification rather than reducing the canonical durable
write set.

## Regression and correction

r1 combined two individually reasonable changes in a harmful way:

1. It eagerly touched every cache key in a batch even though one miss makes the
   all-or-nothing conditional batch ineligible. At this workload's sparse
   working set, that serialized unnecessary LRU work through one actor.
2. It created four child tasks after every PostgreSQL micro-batch for tiny
   cache and counter mutations. Task scheduling cost exceeded the available
   parallelism and amplified short queue bursts.
3. The fixed 60-second snapshot lifetime was shorter than the approximately
   90-second average revisit interval for 90,000 `(room, sender)` keys at
   1,000 messages/s.

r2 therefore:

- performs one batch cache actor hop but stops at the first miss;
- publishes each process-local batch sequentially, one actor hop per owner,
  instead of creating child tasks;
- keeps LRU insertion, promotion and eviction O(1);
- makes the revision-fenced fast-append TTL configurable and uses 600 seconds
  for this profile;
- retains the 131,072-entry hard capacity bound.

PostgreSQL remains authoritative. Every conditional append still verifies the
current room sequence, timeline sequence, membership revision, direct-policy
revisions and shard lease in the transaction. A stale cache entry can only
make the conditional statement affect no row and fall back to the complete
path; it cannot authorize an otherwise denied send.

## End-of-run outlier

The r2 steady window held the append execution maximum to 93 ms. At
`05:32:48Z`, after eight load partitions had completed and started closing
their connections, one final batch took 3,954 ms. The remaining partition
reported 11 retryable `UNAVAILABLE` results while the Gateway simultaneously
processed the synchronized teardown of roughly 40,000 connections. Database
admission queue-full/timeout counters and shard/room credit rejection counters
were all zero.

This is below 0.007% of scheduled messages and does not affect the measured
P99, but it means the run is not a zero-error capacity certification. A future
load scenario should keep all partitions connected through a final no-traffic
barrier or stagger disconnects, then test reconnect/teardown storms as their
own workload instead of overlapping them with the final message drain.

## Verification

- focused fast-cache and runtime-configuration tests passed;
- full disposable PostgreSQL integration suite: 424 tests in 83 suites passed;
- Linux ARM64 Swift 6.3 release build passed;
- deployed image: `imv2-server:tail-lru-batch-finalize-r2-20260826`;
- Gateway health, internal metrics endpoint and public TCP/443 were verified.

The next server-side optimization should not add more actor concurrency. The
remaining steady cost is the PostgreSQL canonical append/projection statements
and their indexes/WAL. Any further change needs an explicit durability and
recovery contract plus a fresh A/B.
