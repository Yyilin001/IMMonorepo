# G5 hot candidates: repeated performance validation

> 历史记录说明（2026-10-13）：本文的代码路径、数据库租约/续期描述及测试结论属于文中固定的旧版本，保留作历史证据。当前房间执行使用原生分布式 Actor activation，在线授权使用主动权限传播与 Host–Gateway 共享控制会话；旧房间租约及 Host dirty-head 控制查询链已移除。历史通过或失败不代表当前版本的验证结果。

Status: **the cached-local candidate passed the complete six-run hot comparison**. Frozen main remains `f1cdd78d6a21bf0ae23da627c0710c65115236aa`; the latest measured candidate is `fb8a10478895f4b2d616f4bf7eb11eed51a84824`. Earlier failures remain below. The operating point and thresholds were frozen before candidate sampling in the [baseline protocol](v1-baseline-protocol.md) and remain unchanged. This is a hot-scenario result, not a production SLO or acceptance of the other four workloads.

## Cached-local candidate (`fb8a1047`)

The [same-process cached invocation change](r3-local-capability-evidence.md#仅限本机的缓存调用) passed native Runtime/Cluster tests and all seven Linux Release products. Its fresh `capacity-formal-hot-cached-local-rate025-campaign` completed the prescribed main/candidate/candidate/main/main/candidate order. All six immutable runners passed correctness, formal eligibility, per-sample frozen assessment and cleanup: each authenticated 100 connections and had 52,500 acknowledged and durable messages, zero workload failures and unchanged room cardinality. The campaign and final six-run assessor exited 0; all six private projects left no containers, networks or volumes, independently checked after the run.

| Sample | ACK/s | CPU ms/ACK | SQL calls/ACK | p95 / p99 ms | Peak PID-1 RSS bytes | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Main 01 | 125 | 1.426372 | 18.352720 | 8 / 10 | 76,529,664 | Pass |
| Candidate 02 | 125 | 2.110377 | 22.115387 | 9 / 12 | 96,448,512 | Pass |
| Candidate 03 | 125 | 2.111085 | 22.112347 | 10 / 12 | 96,669,696 | Pass |
| Main 04 | 125 | 1.415169 | 18.353493 | 8 / 10 | 76,259,328 | Pass |
| Main 05 | 125 | 1.424011 | 18.355547 | 8 / 10 | 76,849,152 | Pass |
| Candidate 06 | 124.996667 | 2.093721 | 22.111416 | 9 / 12 | 96,133,120 | Pass |
| Frozen limits | ≥112.5 | ≤2.133047 | ≤24.775092 | ≤18 / ≤35 | ≤345,440,256 | Unchanged |

Candidate CPU was 2.1103771733333334, 2.1110854133333332 and 2.093720792554468 ms/ACK, all below the frozen 2.13304732 limit; the smallest margin is only about 1%. The three interleaved main accepted rates were all 125/s, giving coefficient of variation **0.0** against the 10% stability bound. Candidate 06 sent 37,500 steady messages but acknowledged 37,499 in that phase; the remaining acknowledgement arrived during cooldown. Its whole run sent, acknowledged and durably stored 52,500 messages, with zero skips, queued tail or workload errors. A phase-boundary acknowledgement is not a lost message. The current final complete Linux run, the other four workloads and fault case #19 remain open.

Evidence: `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-cached-local-rate025-campaign/` contains per-run `assessment-01.json` through `assessment-06.json`, each `passed=true` with no failures. Their SHA-256 values, in order, are `7d5a5671ed7e7cc725895f005c1d8b490f50a4a4140c3f78aadb9a4bd4589b60`, `066acfea0589da38a88c01d414fed3f5d55c624b8947aed474b6370cffe1e85b`, `5fd098dd7547aad985d7b90eb4ddff4b6eb035d118fa366cc35e7ece15e06f5e`, `699e37d13b73d1a26dae84e1401edb6ba549fda664b472dce2280debf838450a`, `d527911eecafbedabf429adb908120a0bbefcb41a916ad2aa972f9d11c57ecea`, `9befc25cc0afe35e08fc6671ad7050062894af38b8fb14ab04db4fc553c97b96`. Each run's `result.json` remains in its own `capacity-formal-hot-cached-local-rate025-interleaved-<NN>-<kind>` directory. The final `six-run-assessment.json` SHA-256 is `b5ec5a973d41ff6a29b30a724c10f2983f90e25e27d32c0b9794de87c5c804cc` (`passed=true`, six runs); `main-stability.json` SHA-256 is `2f60d684206b0c21acbfe719d2c27443fd882b46b4144675211c40f631be40d6` (CV 0.0). The campaign driver SHA-256 is `df98f5d34da76c2b0a042396a84ae288655f31a83e6fcb20820827992c4ac64d`. The original main freeze `f54b433785624c650a8e8d0299107dc54eede182a5a8588edbb35d0b87c85ff4`, common loader, harness, workload and numeric budgets were unchanged. No earlier failed artifact was replaced or reclassified.

## Earlier SQL-context candidate: two fewer SQL calls, CPU still over budget

The [transaction-bound SQL reuse implementation](g5-sql-context-evidence.md) passed ten focused PostgreSQL tests and its seven-product Linux Release build. Its `capacity-formal-hot-sql-context-rate025-campaign` then completed main 01 and candidate 02. Both runners passed correctness, formal eligibility and cleanup: 100 authenticated connections, 52,500 acknowledged and durable messages, zero workload errors, unchanged room count. The outer assessor exited 1 on candidate CPU and stopped before runs 03–06, whose artifact directories do not exist.

| Steady metric | Main 01 | `812af24a` candidate 02 | Frozen limit | Candidate result |
| --- | --- | --- | --- | --- |
| Acknowledgements/s | 125 | 125 | ≥112.5 | Pass |
| p95 / p99 (ms) | 8 / 9 | 9 / 12 | ≤18 / ≤35 | Pass |
| SQL calls / acknowledgement | 18.351973 | 22.109413 | ≤24.775092 | Pass |
| Gateway CPU ms / acknowledgement | 1.401979 | 2.218297 | ≤2.133047 | **Fail** |
| Sampled Gateway PID-1 peak RSS (bytes) | 77,135,872 | 98,390,016 | ≤345,440,256 | Pass |

Only `serverCPUSecondsPerAcceptedUnitMaximum` failed; exact candidate CPU is 2.21829656 ms/ACK against 2.13304732, about 4.0% over. SQL fell by about two calls/ACK from the earlier `c221` sample; CPU fell about 4.3%, but the implementation is not performance-accepted. Actor outstanding peaks were four commands / 1,648 bytes; mean physical send batch size was approximately one. Private project `imv2-va-cap-2228c083200b4769` was cleaned up, with no remaining containers, networks or volumes reported by the runner and independently checked by the verification agent.

Evidence: `/Users/yyl/.codex/virtual-actor-builds/capacity-formal-hot-sql-context-rate025-campaign/assessment-02.json` SHA-256 `c83f44e9088f5af291951886517e0794cacec8d0e32794fcbaefbfdf9882d3e4`; candidate 02 `result.json` SHA-256 `418ec5af01984b61f2003891fa27524b1f7e2c4e1b70ab1f3c6dcff3360ef951`. Main 01 assessment SHA-256 is `f9a863f6651aab0e7521245863e409b8191766730f5b38ed2902ff1af8a65185`, and its result SHA-256 is `fa9d89e9fb5a5ff35955cf9c1c014b8ece2c5c9678637dc860541d439b2c4732`. The separate [candidate-only CPU diagnostic](g5-hot-cpu-profile-evidence.md#later-812af24a-sql-context-candidate-only-diagnostic) has completed: 429 user samples, zero lost, with 12.01% unresolved exclusive leaves. It shows JSON, PostgresNIO/SQL decoding and a few projection-schema regular-expression stacks, but has no contemporaneous main profile and cannot fully attribute the CPU difference. It is excluded from the formal assessor; the CPU failure and unstarted runs 03–06 remain unchanged.

## Earlier local-capability candidate (`c2214c1c`)

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

The formal candidate's `measurement-steady.json` (SHA-256 `2c2465f643d9cc3f088677db8a4125b2a654ddec1f368a56a87e3eae06222915`, in the candidate 02 directory above) identifies the executed write path: its final `singleton_dispatch` counter is 52,500, while atomic batches attempted and committed are both zero. The sampled steady counter delta is 37,454 singleton dispatches; the metrics scrape boundaries differ from the loader's exact 37,500-message steady window. Source tracing maps these singletons through `V2SendMessageAdmissionBatcher.acceptIndividually` to the store's scalar `acceptanceCommit` / `acceptInTransaction` path. An optimization limited to `acceptPlainHybridGroupBatch`, which requires at least two requests, would not affect this measured hot run. Subsequent SQL reuse work must cover the ordinary scalar path while preserving its existing operation/room/lease lock order and excluding forwarding, imports and authorization-receipt preparation from the narrowed optimization.

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
