# G5 hot candidates: functional pass, remaining CPU regression

Status: **performance failed; the latest local-capability candidate passes SQL but still exceeds the frozen CPU limit**. Frozen main is `f1cdd78d6a21bf0ae23da627c0710c65115236aa`; the measured candidates are `171b34ef59c5345709cd6260d081233d7ae89a52`, optimized `fdf6838e9b0276eaf7e90acec3bed5d8fd8511fd`, and local-capability `c2214c1c299e10e7c57ae6260ae232ef3385f7a3`. The hot operating point and thresholds were frozen before candidate sampling as recorded in the [baseline protocol](v1-baseline-protocol.md). Neither load nor thresholds are changed in response to these results.

## Latest local-capability candidate: formal hot gate still failed

The `capacity-formal-hot-local-capability-rate025-campaign` ran main 01 and candidate 02, then exited 1 at the CPU assessment; runs 03–06 were not started. Both immutable runners passed correctness and formal eligibility. Candidate 02 authenticated 100 connections, acknowledged and durably stored all 52,500 messages with zero workload errors, and completed project cleanup. The measured Gateway/container CPU includes the same-process Actor and observer work; it is not a per-function cost.

| Steady metric | Main 01 | `c2214c1c` candidate 02 | Frozen limit | Candidate result |
| --- | --- | --- | --- | --- |
| Acknowledgements/s | 125 | 125 | ≥112.5 | Pass |
| p95 / p99 (ms) | 8 / 10 | 10 / 12 | ≤18 / ≤35 | Pass |
| SQL calls / acknowledgement | 18.350267 | 24.109013 | ≤24.775092 | Pass |
| Gateway CPU ms / acknowledgement | 1.417345 | 2.318061 | ≤2.133047 | **Fail** |
| Sampled Gateway PID-1 peak RSS (bytes) | 76,886,016 | 95,612,928 | ≤345,440,256 | Pass |

The assessor lists only `serverCPUSecondsPerAcceptedUnitMaximum` as failing; Actor outstanding peaks were 5 commands / 2,060 bytes. Candidate CPU is about 16.1% lower than the earlier `fdf6838e` sample's 2.762828 ms/ACK, but this comparison does not attribute the reduction to one function or establish performance acceptance. Immutable evidence: `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-local-capability-rate025-campaign/assessment-02.json` (SHA-256 `f6ce98f3aee8067c8bcc76d49d5eaa97da19c83dcbf04b344a8455d2f194a8e0`) and `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-local-capability-rate025-interleaved-02-candidate/result.json` (SHA-256 `449bc06fc6b78a26cadf9d357d32e696314d2f3219e918d77f3f72a5582b513f`).

A separate [candidate-only CPU diagnostic](g5-hot-cpu-profile-evidence.md#later-c2214c1c-candidate-only-diagnostic) sampled the exact `c221` Release Gateway at the same 125 send/s hot operating point. Its frozen runner exited 0 with 52,500 acknowledged and durable messages, zero workload failures and complete private-project cleanup. The 45-second `task-clock:u` profile collected 437 user samples with zero lost, but 17.02% unresolved exclusive leaves. JSON encoding, SQL/PostgresNIO processing and a few SQL schema regular-expression stacks appear in the sample; these overlapping call paths do not fully explain the CPU excess. No simultaneous main profile was collected. This diagnostic is excluded from the frozen assessor, so the **formal CPU failure remains** and the rest of the six-run campaign stays unstarted.

## Prior optimized-candidate result (`fdf6838e`)

The fresh campaign's main 01 passed, then candidate 02 completed business validation and cleanup but failed its per-sample CPU gate. The driver exited 1 before creating run 03, 04, 05 or 06. Main 01 measured 125 ACK/s, SQL 18.35296 calls/ACK, CPU 1.42774747 ms/ACK and p95/p99 8/10 ms. Candidate 02 authenticated all 100 connections, acknowledged and durably stored all 52,500 full-run messages, and recorded no workload failure. Its steady phase acknowledged 37,499 messages; phase crossing is reconciled by the full-run totals.

| Optimized candidate steady metric | Measured | Frozen limit | Result |
| --- | --- | --- | --- |
| Acknowledgements/s | 124.996667 | ≥112.5 | Pass |
| p95 / p99 (ms) | 11 / 14 | ≤18 / ≤35 | Pass |
| SQL calls / acknowledgement | 24.111950 | ≤24.775092 | Pass |
| Gateway CPU ms / acknowledgement | 2.762828 | ≤2.133047 | **Fail** |
| Sampled Gateway PID-1 peak RSS (bytes) | 96,911,360 | ≤345,440,256 | Pass |

The fixed assessor lists only `serverCPUSecondsPerAcceptedUnitMaximum` as failing. Evidence is in `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-timeouts-rate025-campaign/assessment-02.json` and `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-timeouts-rate025-interleaved-02-candidate/`; the latter's result SHA-256 is `118364020e67511c94a4c752228717722d53b27c8eb013e78a1ba052aa80a0bf`. The task capacity context had no remaining containers or volumes after cleanup. Subsequent CPU profiling will be explicitly diagnostic, outside formal sampling; lowering SQL counts alone has not satisfied the CPU budget.

## First candidate and SQL attribution

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

The external resumable driver had already begun interleaved candidate 03 when candidate 02's budget failure was identified. Its parent was paused to prevent the remaining main/main/candidate runs. Run 03 is explicitly **diagnostic only**, with one additional bounded read of `pg_stat_statements` on each database to map query identities to normalized SQL. The query maps and scope note are in its `diagnostic-pgstat-owner00.csv`, `diagnostic-pgstat-postgres.csv` and `diagnostic-pgstat-scope.json`; each map covers all 55 corresponding identities from candidate 02. Candidate 02's immutable evidence is untouched. Run 03 subsequently completed normal cleanup: project containers, networks and volumes were absent, and the paused orchestration parent was terminated before runs 04–06 started. Its native result had 52,500 acknowledged/durable messages and no workload failure, but it is excluded from formal comparison despite the underlying runner reporting an eligible sample.


The narrow production correction is committed as `fdf6838e`: timeout setup is now two SQL calls per scalar Actor write path instead of nine (one at physical transaction entry, one at the activation fence). A PostgreSQL test now reads all three distinct timeout settings inside the transaction. At this entry, the new Linux Release build and native PostgreSQL regression suites are in progress; no optimized-candidate performance result exists yet.


Native real-PostgreSQL regression completed on the identical production patch (`def0b97b` agent commit, integrated as `fdf6838e`): `V2RoomActivationTransactionDeadlineTests` **1/1**, `V2RoomCreditRefillFencePostgresTests` **2/2**, and `V2SharedRoomSendCommitAckLossTests` **1/1**, all exit 0 and run serially against a fresh task-only PostgreSQL 16. Logs are in `/Users/yyl/.codex/virtual-actor-builds/p0/timeout-query-native/`. The test schema and dedicated database container were removed. Linux Release build and unchanged-budget performance retest remain pending at this entry.


The optimized Linux Release build then completed successfully for all seven products. Its immutable metadata is `/Users/yyl/.codex/virtual-actor-builds/candidate-release-timeouts-fdf6838e/result.json` (`passed: true`, exit 0, source `fdf6838e9b0276eaf7e90acec3bed5d8fd8511fd`). The fresh six-run hot driver `/Users/yyl/.codex/virtual-actor-builds/run-hot-timeouts-campaign.py`, SHA-256 `a6c2e584664caf50a529e12e3ef2be04b5557168152d1d5744144a49e0dacead`, passed its read-only input checks and starts a new main/candidate/candidate/main/main/candidate comparison. It retains the original three main calibrations, freeze, harness `461ef788`, common loader and load. Each sample is assessed before another is launched; an exceeded budget stops the campaign immediately. At this entry, the new comparison has begun and has no completed optimized-candidate sample.
