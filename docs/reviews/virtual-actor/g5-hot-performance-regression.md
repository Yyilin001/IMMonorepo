# G5 first hot candidate: functional pass, performance failure

Status: **performance failed; production optimization and a new candidate comparison pending**. Frozen main is `f1cdd78d6a21bf0ae23da627c0710c65115236aa`; this measured candidate is `171b34ef59c5345709cd6260d081233d7ae89a52`. The hot operating point and thresholds were frozen before candidate sampling as recorded in the [baseline protocol](v1-baseline-protocol.md). Neither load nor thresholds are changed in response to this result.

The first interleaved candidate completed the immutable runner successfully: 100 authenticated connections, 52,500 total sends/acknowledgements/durable messages, no workload failures/skips/overflow, unchanged room count, no admission rejection and successful cleanup. Its artifact is `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-rate025-interleaved-02-candidate`. Runner validity does not constitute performance acceptance.

| Steady metric | Interleaved main 01 | Candidate 02 | Frozen limit | Candidate result |
| --- | --- | --- | --- | --- |
| Acknowledgements/s | 125.0033 | 125 | ≥112.5 | Pass |
| p95 / p99 (ms) | 8 / 10 | 11 / 14 | ≤18 / ≤35 | Pass |
| SQL calls / acknowledgement | 18.350817 | 31.119360 | ≤24.775092 | **Fail** |
| Gateway CPU ms / acknowledgement | 1.450112 | 2.947645 | ≤2.133047 | **Fail** |
| Sampled Gateway PID-1 peak RSS (bytes) | 76,722,176 | 96,043,008 | ≤345,440,256 | Pass |

Main acknowledged one warmup message during steady, explaining its 37,501 acknowledgements against 37,500 steady sends. Candidate acknowledged 37,500. Full-run message accounting matches on both revisions. Frozen CPU and other limits derive from the earlier three main calibration medians, not from this one interleaved main sample.

## Attribution and comparison checks

Both runs use the same clean harness `461ef788`, common loader, fixture/scenario, 4 CPU / 16 GiB VM and boot ID, database images/settings, resource limits and 300-second phase. After removing random project and loader revision labels, their recorded Compose settings are identical. Each steady phase has 54 periodic observations; average observation durations were about 0.174 and 0.173 seconds. Gateway cgroup CPU includes its same-process Actor, metrics and background workers; all-database SQL includes observers/background work. Those scope limits remain, but external observations do not explain the per-message growth below.

Owner SQL rose from 675,556 to 1,126,376 calls. Four candidate-only query identities account for 450,426 of the 450,820 additional calls:

| Query | Candidate steady calls | Calls per acknowledgement |
| --- | --- | --- |
| `SELECT set_config(...)` | 337,767 | 9.007 |
| `rooms ... FOR NO KEY UPDATE` | 37,553 | 1.001 |
| `room_activation_leases ... FOR UPDATE` | 37,553 | 1.001 |
| `SELECT clock_timestamp()` | 37,553 | 1.001 |

Control SQL rose from 12,618 to 40,600 calls; its `room_owner_routes` lookup ran 30,092 times on candidate. The room and activation locks and database clock are the actual write fence. The dominant avoidable work is instead three repeated applications of the same three LOCAL timeout settings: physical transaction entry, `PostgresV2RoomWriteStore` transaction wrapper, and activation fence.

The proposed narrow correction combines the three independent LOCAL settings into one SQL statement and removes the middle duplicate where physical transaction entry already guarantees the same settings. Physical transaction setup, the fence's settings, room/lease locks, the absolute-deadline watchdog and unknown-result handling remain. It must pass real PostgreSQL timeout/fence tests and then a new comparison at the original 125 messages/s and original thresholds; this document does not claim the optimization has passed.

## Stopped campaign and diagnostic run

The external resumable driver had already begun interleaved candidate 03 when candidate 02's budget failure was identified. Its parent was paused to prevent the remaining main/main/candidate runs. Run 03 is explicitly **diagnostic only**, with one additional bounded read of `pg_stat_statements` on each database to map query identities to normalized SQL. The query maps and scope note are in its `diagnostic-pgstat-owner00.csv`, `diagnostic-pgstat-postgres.csv` and `diagnostic-pgstat-scope.json`; each map covers all 55 corresponding identities from candidate 02. Candidate 02's immutable evidence is untouched. Run 03 is allowed to complete normal cleanup and is excluded from formal comparison, even if its underlying runner reports an eligible sample.
