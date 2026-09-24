# Same-owner relative performance

Status: **main calibration frozen; cached-local candidate `fb8a1047` failed the CPU budget in its first interleaved sample**. Business correctness, throughput, latency, SQL and sampled RSS passed that sample. Runs 03–06 were not started. This is a failed comparison, not performance acceptance.

The [baseline protocol](v1-baseline-protocol.md#frozen-same-owner-operating-point) records the original failed FD-limit attempt, the subsequent main admission timeout, the pre-candidate rate reduction, and three complete main calibrations. The frozen operating point is 1,500 connections, 141 rooms on one owner, one common Linux loader, 450 sends/s and 120/300/60-second phases. Main remains `f1cdd78d6a21bf0ae23da627c0710c65115236aa`; candidate remains `fb8a10478895f4b2d616f4bf7eb11eed51a84824`; both use clean harness `28244fdf699657a39157a362e5f59850e7d47388`. Gateway and loader each verified PID-1 soft/hard open-file limits of 65,536, with private evidence hashes bound into the result and measurement.

## First interleaved pair

Both runs authenticated all 1,500 connections and completed 189,000 sends, acknowledgements and durable messages, with zero business/connection failures, skipped messages or loader overflow. Room cardinality was unchanged. The runner and project cleanup succeeded for each run; the outer campaign exited 1 after the candidate CPU assessment. All private containers, networks and volumes were removed.

| Steady measurement | Main 01 | Candidate 02 | Frozen candidate limit |
| --- | --- | --- | --- |
| Acknowledged messages/s | 450 | 450 | ≥405 |
| p95 / p99 (ms) | 52 / 59 | 64 / 73 | ≤65 / ≤88.5 |
| Gateway CPU (ms/ACK) | 1.051153 | 1.669407 | ≤1.562289 |
| SQL calls/ACK | 18.089170 | 22.585681 | ≤24.415220 |
| Gateway sampled peak RSS (bytes) | 173,436,928 | 219,848,704 | ≤439,787,520 |
| Loader CPU (ms/ACK) | 0.056572 | 0.055502 | Recorded separately |

Candidate CPU exceeded the unchanged ceiling by approximately 6.86%. Its 300-second steady window consumed 225.369906 Gateway CPU seconds and 7.492737 loader CPU seconds. SQL counters covered 3,049,067 calls across owner/control databases, including background and observer statements. Sampled active rooms peaked at 141; outstanding Actor work peaked at 63 commands and 25,956 bytes, within the existing bounds. The phase-counter ratio labelled mean physical send batch size was 0.999940669, with counters captured across phase boundaries; it does not establish multi-message batching. Main did not expose that metric, so its value remains unavailable.

The candidate-only diagnostic and subsequent allocation changes are recorded below. The failed pair and freeze remain immutable. No load, budget, admission limit or correctness rule is relaxed in response to the candidate result.

## Immutable evidence

Artifacts are under `/Users/yyl/.codex/virtual-actor-builds/`, with prefix `capacity-formal-same-owner-cached-local-fb8a1047-attempt03-`. The external driver is `run-capacity-workload-campaign.py`, SHA-256 `865747c013777b1df77aca41a2e2330627ac5d65475249ec723951a3adaa09c8`; its full log is `same-owner-cached-local-fb8a1047-attempt03-driver.log`.

| Artifact suffix | SHA-256 |
| --- | --- |
| `campaign/main-calibration-freeze.json` | `15c0f97524bde2e8197a145f5fa3bcfb1f413b1472dc9b3d59f3d4e53276ef15` |
| `interleaved-01-main/result.json` | `3b689d0b82b17a59106064ed81df703a47344b98e92b4ddeaad4fe6c27ef895f` |
| `interleaved-02-candidate/result.json` | `b1659062d919c51d685522206da8979612f66aa7daa48950f5eaed418cd82aa4` |
| `interleaved-02-candidate/load-report.json` | `ed68ee4f62910738fe3e968b6c2be75f4a101076b6276b0b4c238b862ba636a3` |
| `interleaved-02-candidate/measurement-steady.json` | `ea45229195a21c8b1fa569d0b8193181b835f4211e2eab2a96e24b999c61635e` |
| Main 01 per-sample budget in `campaign/` | `f058e005e963799c57cec68c5cbc3359d971e9b34bc877be161d5d3556a3fa38` |
| Candidate 02 per-sample budget in `campaign/` | `3fad45af45eb788380974e0a4947d94df8f889e968c4c274b723035b8b4f3990` |

Each budget filename is `budget-` followed by its full run directory name and `.json`. Independent offline verification matched both budget result hashes, recomputed their assessment, and checked both PID-1 evidence hashes against the result and measurement. No six-run assessment or final interleaved-main stability report exists for this stopped campaign. The earlier hot six-run pass remains scoped to its own workload; same-owner, mixed, cold, fault/#19 and the current-source full Linux gate remain incomplete.

## Candidate-only CPU diagnostic

A separate diagnostic retained candidate `fb8a1047`, harness `28244fdf`, common loader, fixture, 1,500 connections, 450 sends/s and full 120/300/60-second phases. Its external driver `run-same-owner-cpu-diagnostic-cached-local-fb8a1047.py` has SHA-256 `16bbab2f17d8674037750569b94ccd369c56ec6fc55b417cb3eebabbb102bb72`. It sampled Gateway PID 1 with `task-clock:u`, 49 Hz and DWARF call chains for 45 seconds, starting 20 seconds into steady state. Only the private profiler sidecar received `PERFMON`; Gateway and VM capabilities were unchanged. This is not a formal sample and does not replace the failed CPU assessment. No contemporaneous main profile was collected.

The diagnostic driver and business runner exited 0, with all 1,500 connections authenticated and 189,000 acknowledged/durable messages, zero business failures and successful cleanup. The private project `imv2-va-cap-7a363f23729143d4` and all five sampler/report containers were removed. The measured profile wall interval was 46.417078 seconds; Gateway cgroup CPU was 36.668887 seconds, and PID 1 user/system CPU was 26.53/9.60 seconds. There were **1,269 user samples and zero lost samples**. The report abbreviates its sample count as `1K`; the copied analyzer now checks the exact record count against all 1,269 event headers in the offline script, rather than treating `1K` as 1,000. Both report event identities and lost counters are required.

Sampled exclusive leaves include `swift_release` 4.33% and `swift_retain` 3.62%. Inclusive paths include JSON generic encoding 7.25%, PostgresNIO channel reads 13.87% and SQL-row decoding 5.67%; these overlap and cannot be summed. `swift_job_run` has 49.96% inclusive coverage because it parents task work, not because scheduling consumes that fraction. Unresolved exclusive leaves account for 21.11%, predominantly stripped libc (18.17%). Individual rounded exclusive rows sum to 100.99%, so the table is an approximate profile, not an exact cost decomposition. The inclusive report emitted six `addr2line` warnings, limiting source-line attribution; `task-clock:u` excludes the separately measured system CPU. This evidence supports investigating allocation and encoding/database paths but cannot assign the full formal CPU excess to one function or predict a precise saving.

Private artifacts are under `/Users/yyl/.codex/virtual-actor-builds/capacity-same-owner-cpu-diagnostic-cached-local-fb8a1047/`:

| Artifact | SHA-256 |
| --- | --- |
| `candidate/result.json` | `ec2aebce9d8a79e548de5ea1ce253a55eed30e660bf0f8cd059c338fc46c058d` |
| `candidate-freeze-profile/perf.data` | `ff9480b560f574aaeacdecdb337603bc15ad285514d93adbfbc616a6b1d8f2a5` |
| `candidate-freeze-profile/scope.json` | `ed5218345e59637f891287c892728a1f8d0f39b02de56bb9f1a2ffd5b427a6d2` |
| `candidate-freeze-profile/symfs-manifest.json` | `9be0c5d32fee754beb2695cc5179f7697ec2243751fd55a48827356b666d2abd` |
| `candidate-freeze-profile/perf-script-offline.txt` | `3a54a772e1137e9e8bcac9d8239a2c456a67c3a7b42040fe220948e38094f64d` |
| `candidate-profile-summary-offline.json` | `77ec59aaeccfee2bf653382bb61cbc38f0c6d8df461caa4130303d5ac04a3cad` |
| `analyze_cpu_profiles.py` | `23467c2ee92aa76cc997343bd472bff38639c996cb4df4675c8eaf149997e149` |

The live Gateway and saved ELF both match Release SHA-256 `6e336cd3860777977789fa960770907e5b52efeda52e1ad154857ce091a5900d`; all eight saved DSO hashes were independently verified. Raw data and aggregate summaries remain private. The proposed small allocation optimizations must retain byte limits, command ordering, physical-call tracking, room/lease locks and the database clock check after lock acquisition. Their actual benefit remains subject to fresh formal comparisons under the original hot and same-owner freezes.

## Allocation candidate `2772c846`

The next immutable candidate is `2772c8465a58ef4ca3c9eab44b685ab5753b78a9`, in `/Users/yyl/.codex/worktrees/virtual-actor-candidate-allocation/IMMonorepo`. It contains three small changes developed in separate worktrees and reviewed together:

- The transaction-bound fence uses a direct UUID lookup when there is exactly one room and the requested SQL timeouts equal the installed policy. It avoids building the multi-room set, sort, JSON array and lookup dictionary. The one-shot context, error priority, room lock, lease lock and separate database clock observation remain in order. Multiple rooms and different timeout policies retain the original path.
- The client registers a dispatched RPC before starting one task that executes and records its physical completion. Caller cancellation or timeout still detaches only the caller; the in-flight entry and client remain alive until the operation returns.
- A batch size of one removes the first pending request whose room is not active through the original removal/accounting path. This avoids the later repeated scan and room-set copy while preserving per-room FIFO, shared capacity release and granted-owner handling. The original size-one path already returned before the second batching pass; this change does not claim to remove that second pass.

Native Runtime, Cluster, send-service and real PostgreSQL regressions passed **139/139 with zero skips**: Runtime 58, Cluster 36, send-service 29 and 16 database cases. Four new tests actually started and passed, covering scalar fence errors, late physical completion after caller cancellation, active-room/FIFO behavior and pending-capacity return. Existing multi-room batching, stale activation, total transaction deadline, credit refill, successful COMMIT ACK loss, Host overload/drain and maintenance takeover cases also passed. The source stayed clean and the lockfile remained `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`.

The first external driver exited 1 after miscounting a parameterized Cluster pass line; the underlying Runtime and Cluster test processes exited 0 with positive 58/36 summaries. The original failed artifact and driver `932d72feb16e1d49004390054fb485af05ed3044b5b7d990000471b6cc7d7073` remain unchanged. A corrected parser independently revalidated those two logs without rerunning them, then a new invocation ran the remaining 12 filters (45 tests). Its driver SHA-256 is `bd0d471e137d51e7e42df0d83a7e737c827e38e71ef30c51b8efe7aa30d18f63`. Both invocations removed all their private PostgreSQL containers; readiness required authenticated TCP `SELECT 1`.

| Native evidence under `/Users/yyl/.codex/virtual-actor-builds/p0/` | SHA-256 |
| --- | --- |
| `scalar-fence-native-2772c846/runtime.log` | `4d81df940cf0c531ab169331218cb63e4ecc148f6a097f593417a65e9dfa96ed` |
| `scalar-fence-native-2772c846/cluster.log` | `79277c285f4d875a80f5f59a77f91e4b132a0156f5830831db226ac38439a78c` |
| `scalar-fence-native-2772c846-offline-revalidation/result.json` | `dd036be3d5239cd6e55c8c80615a668d8c6acbe9a93bdd296c3aa86468a72d28` |
| `scalar-fence-native-2772c846-continued/result.json` | `94baafacb06ebf6848f1fc08e3946118855ce8bb83cc55a47b570dab1a761061` |

Linux Release, fresh six-run hot/same-owner comparisons and the final complete Linux gate remain pending for this candidate. Native regressions do not establish CPU savings or replace those gates. The new same-owner comparison driver pins the original `15c0f975` freeze, all three original main calibration results and the same harness, loader and workload; it starts six fresh interleaved runs and stops on any failed budget. No previous candidate sample is reused.
