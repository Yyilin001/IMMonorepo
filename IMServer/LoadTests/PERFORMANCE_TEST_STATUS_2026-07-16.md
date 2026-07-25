# Performance Test Status - 2026-07-16

## Scope and Topology

- Gateway: 8 vCPU / 16 GiB ARM, public HTTP `:8080`, TCP `:9000`.
- Base services: 8 vCPU / 16 GiB ARM, PostgreSQL, Redis, Kafka, outbox relay,
  summary projection, and domain delivery consumer.
- Two independent load generators were used for the TCP online tests. HTTP and
  sync smoke tests ran from the local workstation through the public gateway
  and the private command API tunnel.
- TCP online tests use prewarmed login caches. HTTP login capacity is a separate
  workload and is not included in TCP online capacity conclusions.

## Valid Results

| Scenario | Load | Result | Key measurements |
| --- | --- | --- | --- |
| TCP online | 10,000 total connections | Pass | 10,000/10,000 authenticated; heartbeat ack 1,611,088/1,611,088. |
| TCP online | 20,000 total connections | Pass | 20,000/20,000 authenticated; 15 minute hold; heartbeat acks complete. |
| TCP online | 30,000 target | Not stable | About 23,000 authenticated before auth/open timeouts. No TCP connection-limit rejection. |
| Direct TCP delivery | 2 connections, 2 msg/s, 10 s | Pass | 20 accepted messages, 40/40 expected deliveries; P50 142 ms, P95 1.05 s, P99 5.45 s. |
| Small group TCP delivery | 50 members, 5 msg/s, 30 s | Pass | 150 accepted messages, 7,500/7,500 deliveries; P50 172 ms, P95 185 ms, P99 575 ms. |
| Large group TCP delivery | 499 online recipients, 10 msg/s, 30 s | Correct but slow | 300 accepted messages, 149,700/149,700 deliveries; P50 12.25 s, P95 20.28 s, P99 20.84 s. |
| Direct message convergence | 2 VUs, 30 s | Pass | 121 cycles, zero errors; accept P95 43 ms, timeline P95 222 ms, summary P95 674 ms. |
| Direct message lifecycle | 1 VU, 30 s | Pass | 12 complete bidirectional cycles; 50/50 checks; total P95 2.44 s; mark-read P95 80 ms. |
| Offline catch-up | 3 VUs, 30 s | Pass | 112 cycles, 899 checks; write P95 176 ms, read P95 38 ms, end-to-end P95 487 ms. |
| Inbox fanout and sync | 3 VUs, five test conversations, 30 s | Pass | 114 cycles, 1,027 checks; write P95 36 ms, list P95 167 ms, changes P95 165 ms, timeline/since P95 159 ms. |

## Environment Findings

PostgreSQL originally used the default `max_connections=100`. The five Swift
service processes collectively held 97 idle application connections, so normal
requests could fail with PostgreSQL `53300` (reserved connection slots). This
also contaminated the first offline catch-up run and likely contributed to the
30,000 TCP auth timeout boundary.

For this temporary performance environment, PostgreSQL was changed to
`max_connections=300`. After restart and service recovery, all roles were
healthy and the observed connection count was 108/300. This is an environment
mitigation, not the final production pool-sizing design. Role-specific event
loop and database pool budgets still need to be made explicit before a
production deployment.

## Test Harness Fixes Included in This Worktree

- All K6 message catch-up calls use `/timeline/since`; `/messages/since` is not
  a server route.
- Offline and inbox changes calls now capture the real pre-write `snapshotToken`
  instead of using a stale synthetic cursor.
- Core convergence, direct lifecycle, multi-device, read-state, forwarding, and
  inbox cursors now use `timelineSequence`, while summary and read-state
  assertions continue to use `serverSequence`. These are different sequences.
- TCP driver output tracks accepted message acknowledgements and expected
  end-to-end deliveries separately.
- Direct lifecycle and multi-device tests now follow the actual `markRead`
  contract: synchronous HTTP 200 read-state response, not an asynchronous 202
  command receipt.

## Known Blockers and Interpretation Rules

1. The post-restart direct convergence attempt that timed out during a roughly
   50 second Kafka catch-up interval is a recovery-path observation, not a
   steady-state latency result. The later steady-state run is the valid
   comparison point.
2. The 499-recipient group result proves delivery correctness but not good user
   experience. Its 12-21 second delivery range makes large-group fanout the
   dominant service-side scalability problem.
3. The 20,000 TCP result is the current validated online capacity. The 30,000
   attempt is a boundary signal, not proof of a 23,000 hard maximum, because it
   happened before the database connection budget was corrected.

## Next Test Order

1. Repeat the 30,000 TCP cache-only hold after the PostgreSQL pool budget is
   explicitly configured; then run 25,000 and 30,000 as separate steps.
2. Use the existing 499-member group for 5, 10, 30, and 50 msg/s sustained
   tests with drain accounting. Record Kafka lag, domain delivery batch time,
   relay payload bytes, and recipient delivery percentiles for every step.
3. Do not use the large-group numbers as a production commitment until the
   fanout consumer and relay payload path meet a target latency budget.
