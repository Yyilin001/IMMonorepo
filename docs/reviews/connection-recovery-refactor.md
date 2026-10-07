# Gateway connection and recovery ownership refactor

Status: room authorization and online message delivery now have independent
sequence checkpoints, bounded outboxes, actual-call admission and receipts.
Capacity acceptance remains open; no performance improvement is claimed.

## Current room permission/message boundary

- The internal Actor delivery protocol requires `deliverySequence` and
  `authorizationSequence`. Old wire decoding and mixed production ACK APIs
  are removed; Room and Gateway processes must use the same new protocol.
- Only permission controls advance the authorization checkpoint. A missing
  body/head is recovered from committed room progress without clearing members.
  Missing permission controls still fail closed.
- Separate bounded authorization/message outboxes use one lane-worker
  implementation with independent RPC ownership and peer retry reservations.
  Message calls use the configured call limit; controls reserve at most two
  additional calls. Pressure retains one deferred maximum H rather than forcing
  a permission baseline. Each lane's receipt retires only that lane.
- Warm permission renewal neither owns the message mutation turn, reads members,
  acknowledges bodies, nor publishes H. Trusted progress publication is a
  separate operation; H survives permission recovery within the same data owner.
- The trusted host permission feed immediately retires old grants on a newer
  control version, even while a message database read is held. A complete fresh
  permission cut replaces the old cut without replaying every preceding body.
  Unsubscribe reduces existing authority without querying members or catching
  up messages. Cold subscribe/activation and changed permission cuts still use
  trusted snapshots; expiry and actual socket permit validation remain enforced.
- All in-flight renewals, binding installs and actual lane RPCs remain owned until
  completion, including shutdown. No large load run is part of this rewrite's
  deterministic acceptance.

Validation: 84 affected Swift tests passed (80 server tests and 4 signed/real
Cluster transport tests), including held-body revocation, held-database-read
renewal/invalidation, independent H retention and actual TCP callbacks.
The debug build and `git diff --check` passed. No capacity result is claimed.

## Scope

Implement the reviewed separation of connection identity/indexes, confirmed
connection lease authority, scope recovery state, actual authorization query
execution, and connection-local outbound ownership. Retain native distributed
Gateway endpoints and existing persistent message/receipt/wake semantics.
The unrelated unfinished host-aware Wake Relay draft is outside this change.

## Completion requirements

- Connection identity and routing indexes have one owner. No mirror maps.
- Scope generation, demand H, authorization proof, coverage confirmation and
  recovery attempt state have one independent recovery coordinator owner.
- Actual permission query slots end after query/result settlement; they never
  wait for a socket writer. Maximum actual query attempts remains four.
- Result positions are reserved before query dispatch and transferred exactly
  once; queued, in-flight reservations and prepared results share a bounded
  capacity ledger. Cancellation cannot lend a still-owned position.
- Outbound retention is bounded, connection-local, separate from actual socket
  admission, and revoked synchronously before shutdown waits.
- Scope/lifecycle/attempt/revision checks and original authorization deadlines
  survive every asynchronous boundary and actual socket admission.
- Watermarks merge monotonically; old results never overwrite a newer demand.
- Aggregate interests release exact ownership; one device's departure cannot
  remove another device's subscription.
- Confirmed lease deadlines originate from successful database observations;
  unknown/failed renewals never extend authority. Late admission compensates.
- Pending IDs, subscription scopes, encoded frames and retained closures are
  accounted for under explicit existing connection/subscription/byte budgets.
- Root tasks have owners; bounded batches use structured children and actual
  shutdown drain. No per-notification fire-and-forget tasks.
- Room recovery cold resolution begins before warm host awaits; host calls
  progress independently under a Directory-wide four-call physical budget.

## Verification policy

Compile only affected targets while integrating. Execute meaningful affected
lifecycle/backpressure tests once sources stabilize; rerun only failing or
changed checks. Deterministic gates validate delayed writers, revoked scopes,
query completion, proof expiry and actual drain without capacity benchmarks.
Then retain the original 10k/1000 -> 50k/1000 -> 5000 capacity gates; no quality,
TTL, observation-window or denominator relaxation. Passing unit tests alone
is not capacity acceptance. Source/binary identity must be recorded for any
runtime comparison; the unrelated Relay draft must not contaminate comparison.

## Implementation record

- Root: Directory recovery host admission and progressive cold/warm dispatch;
  focused gated Runtime tests, integration builds and final verification.
- Recovery agent: Registry recovery/authorization state and execution ownership,
  production integration of independent lease and outbound helpers.
- Outbound agent: bounded actual handoff ownership and connection index owner.
- Lease agent: monotonic confirmed leases, renewal and compensation ownership.

Detailed ownership, protocols, invariants, official references and rollout are
in [the Chinese design](connection-recovery-refactor-design.zh-CN.md).

## Verification so far

- Runtime target compiled in 11.57s; affected Runtime test target compiled in
  4.10s before the progressive cold-result followup.
- First Gateway integration target compiled in 11.07s.
- Focused test build completed in 114.49s. Five lease/outbound test functions
  and three Runtime functions passed (10 parameter cases total). Log:
  `/tmp/imv2-registry-refactor-focused-tests.log`.
- Next integration build completed in 47.41s, but the run was terminated after
  a confirmed live helper stopped making progress. Inspection found the
  existing gated-admission test awaits unregister before releasing admission;
  the new synchronous cleanup awaited that admission. This introduced a close
  dependency and is being corrected with owned two-phase cleanup. No pass is
  claimed for that interrupted test selection. Log:
  `/tmp/imv2-registry-refactor-integration-tests.log`.
- The two-phase cleanup correction passed the affected lease tests and the
  original late-admission compensation test. An independent recovery coordinator
  now owns scope state and the original bounded scheduling ledger.
- Next focused run built in 61.60s and executed 19 functions in 0.628s: 18 passed,
  including five suspended writers allowing new authorization, proof expiry,
  synchronous shutdown revocation and actual drain. One failed assertion still
  counted a blocked socket as an actual query; it has been changed to assert
  outbound retention plus query-slot release and actual drain. This is not yet
  a passing result for the corrected assertion. Log:
  `/tmp/imv2-registry-refactor-coordinator-tests-2.log`.
- Dependency analysis: 672 files, zero forbidden edges and zero cross-target
  strongly connected components. Server boundary check: zero exceptions.
- Final focused compile found Swift Testing macro Sendable inference errors in
  the new coordinator permit tests; production compiled. Test expressions now
  evaluate closure calls into local Bool values before assertion. No test pass
  is claimed for that compile failure. Log:
  `/tmp/imv2-registry-refactor-final-tests.log`.
- Final source audit corrected reordered scope intent, persistent write
  revocation, original presence-proof deadline through Ready, and per-kind
  actual coverage writer exclusion. Actual control-worker shutdown ownership
  and valid prepared-proof reuse are receiving final integration.
- Final lifecycle/ownership tests and capacity verification remain open.
- Latest run built in 66.00s and executed 20 functions in 2.012s; 16 passed and
  four failed. New coordinator generation/shutdown tests, real control-worker
  shutdown join, valid-proof reuse, permission-expiry reauthorization, five
  blocked writers and bounded return ownership passed. Remaining failures
  exposed query/short-handoff scheduler coupling, duplicate presence observation
  after periodic refresh, an authentication-bypassing presence fixture, and
  sampling transient/coalesced outbound state. Fixes retain query concurrency
  four, the original 1024-position ledger, and actual drain semantics. They are
  in progress; no passing result is claimed for this selection. Log:
  `/tmp/imv2-registry-refactor-final-tests-2.log`.
- Separate query/control lanes and shared original presence-proof reuse were
  then implemented. The affected run built in 37.20s and executed 14 functions
  in 0.528s: 12 passed, including all four coordinator authority tests, actual
  blocked-query fairness, prepared cohort isolation, same-proof retry, original
  TTL expiry and both room/presence successor fencing. Two remaining tests
  exposed fixture assumptions: a presence recorder counted control frames after
  switching to the real handshake, and a capacity assertion expected a freed
  predecessor position to be refilled even while its query remained actual.
  Their corrections are being verified separately. Log:
  `/tmp/imv2-registry-refactor-phase-tests.log`.
- Final two corrected regressions built in 31.20s and both passed in 0.470s.
  Presence counts only actual presence frames after real authentication;
  protected queue capacity explicitly moves 1024 -> 1023 when one obsolete
  predecessor returns its position, without a new artificial refill. Log:
  `/tmp/imv2-registry-refactor-final-regressions.log`.
- Changed production sources compile. All selected affected checks have now
  passed in their relevant runs: connection leases, presence query ownership,
  connection-local outbound capacity/control-worker drain, coordinator
  generation/deadline fences, Registry fairness/proof/position ownership,
  and Directory cold resolution/global actual host budget. Passing groups were
  not repeatedly rerun after unrelated changes; final reruns covered the failing
  or materially changed cases only. No database service or capacity benchmark
  was started for this refactor.
- Source identity for review is recorded in
  `/tmp/imv2-registry-refactor-source-manifest.json`; old Release load-test
  binary has not been replaced or claimed to match this implementation.
- Remaining acceptance: original runtime capacity gates and comparison against
  an explicitly identified source/binary baseline. Fully cold per-scope presence
  recovery still has a bounded single-key path; global cold-key deduplication is
  not claimed. The unrelated preexisting Relay draft remains unverified here.

## Subsequent ownership audit (integration in progress)

The earlier passing source identity is superseded by the changes below; no new
compile or runtime pass is claimed for this in-flight source snapshot.

- Registry now invalidates the foreground fast path before its first unregister
  suspension. A real-handshake regression gates interest cleanup and verifies
  that no new foreground write is accepted while unregister is suspended.
- Publication-policy SQL now belongs to the lease controller's actual operation
  ledger. Concurrent authoritative renewals join one owned per-lifecycle task.
  The new delayed-SQL and singleflight regressions are not yet run.
- Interest release no longer allocates an overflow ticket/waiter queue or crashes
  at an unproven pending bound. The executor owns at most 1024 tickets and four
  actual workers; integration must keep refused tickets with their original
  lifecycle owner until bounded ownership transfer.
- Presence refresh scheduling and exact per-target result settlement are being
  migrated together to an independent coordinator.
- Shared-interest owner changes currently amplify underlying activation calls;
  confirmed physical-state reuse is being implemented with reconciliation.
- Pre-rebuild server/account/Loader artifacts are preserved with hashes under
  `/tmp/imv2-registry-refactor-pre-rebuild-binaries-20261003/manifest.json`.
  Legacy reference executables are present under the baseline checkout's
  `IMV2Server/.build/release`; the Loader artifact still matches the canonical
  current measurement algorithm and uses TCP/TCP-query for message transport.

Source stabilization, the focused new/affected regressions and unchanged staged
capacity gates remain required. The preexisting Relay draft prevents attributing
a whole-tree runtime delta solely to the Registry refactor.

## Ownership integration verification

- The first audit test build failed on Swift 6 isolation: a new Shared-interest
  batch closure captured mutable Entry state. It now reports completion through
  the owning actor and checks the exact operation ID; no unchecked Sendable was
  introduced. Log: `/tmp/imv2-registry-refactor-ownership-audit-tests.log`.
- Corrected build completed in 62.54s; 26 tests in six suites passed in 0.006s.
  Selected coverage includes lease singleflight/publication actual ownership,
  exact interest release and delayed activation, zero-overflow cleanup capacity,
  Shared physical-state reuse and interleaved replacement, real authentication
  then unregister foreground revocation, migrated Presence query/settlement,
  five blocked writers and shutdown joining actual Ready admission. Log:
  `/tmp/imv2-registry-refactor-ownership-audit-tests-2.log`.
- Boundary verification passed: 675 files, 70 overrides, 2542 symbols, 2673
  edges, zero forbidden edges and zero cross-target cycles. Output:
  `/tmp/imv2-registry-refactor-ownership-audit-boundaries.md`.
- No capacity benchmark has been started. Follow-up source work remains:
  separate cold interest activation from actual query roots, replace repeated
  whole-owner-table cleanup scans with exact kind lookups, join outbound tickets
  of already-retired streams, and expose the migrated Presence owner's actual
  stages in runtime observability. This test pass does not prove those future
  changes or the runtime capacity gates.

## Stage integration verification (2026-10-03)

- Cold-interest, room/Presence query, and short control roots now have separate
  four-slot admission; all roots remain bounded by twelve and the original
  1024-position transfer ledger. Presence SQL no longer waits in control.
- Exact interest acquisition receipts do not grant viewer permission. Interest
  cleanup uses fixed-kind lookups and a retired-only scheduling index; releases
  waiting on actual activation retain ticket capacity without occupying eligible
  release workers.
- Registry now retains retired writer cleanup under the Directory connection
  operation budget, uses at most sixteen independent owned drain roots, and
  joins both active and retired streams at shutdown. ByteStream permanent
  revocation prevents new control retry workers after drain.
- Production metrics distinguish scope aliases, stage roots, provider attempts,
  Presence query batches/target tickets, and retired writer actual ownership.
- Unified affected run: build 63.45 seconds; 25 tests in seven suites PASS in
  0.655 seconds. Includes cold-four/warm-query progression, four Presence waits
  with typing control, eligible interest cleanup, real-auth unregister revocation,
  both active/retired Ready gates, retired non-Ready retry drain, original scope
  return bounds, Presence target fencing and metrics rendering.
  Log: `/tmp/imv2-registry-refactor-stage-integration-tests.log`.
- Boundary checks PASS: 675 files, 70 overrides, 2545 symbols, 2674 edges,
  zero forbidden edges, zero cross-target SCCs.
  Evidence: `/tmp/imv2-registry-refactor-stage-boundaries.md`.
- Frozen Swift-source inventory: 2000 files, SHA256
  `92c7346fd75238c4c79c34869804772ea1456b8eb3174cc7dedc0c74ac5c5d35`,
  `/tmp/imv2-registry-refactor-stage-source-manifest-20261003.json`.
- Release build and unchanged 10k/1000 -> 50k/1000 -> formal 50k/5000 gates
  remain open. Unit tests do not establish throughput or production drain.
  Legacy whole-tree comparison does not isolate Registry causality because
  the worktree includes earlier unrelated routing/Relay changes.

## Final waiting-boundary audit

- Real room hints losing their coverage session now downgrade by exact demand
  version and return to query admission. They cannot fall through control into
  a scalar permission query. Fifteen affected authority/fairness/TTL/inline tests
  PASS in 0.674 seconds; build 83.29 seconds. Log:
  `/tmp/imv2-registry-refactor-hint-fence-tests.log`.
- Presence query-active keys formerly remained blocked until old socket result
  settlement. New-device preparations could consequently occupy all four shared
  query roots without performing SQL. Query keys now transfer synchronously into
  exact `(batchID, request)` result positions. Total pending + query-active +
  retained-result capacity remains 1024. Old callbacks only settle their own
  result position, never a successor active query.
- Control roots no longer await stale account interest compensation; exact
  lifecycle cleanup and the actual acquisition root retain that responsibility.
- Seven affected tests in four suites PASS in 0.604 seconds, including same-key
  new-device SQL while old output is held, old-result/new-query isolation, original
  proof deadline reuse, multi-device Presence fencing, actual account-interest
  drain, invalid room-hint admission and production metrics. Log:
  `/tmp/imv2-registry-refactor-presence-position-tests.log`.
- Acceptance source inventory supersedes prior snapshots: 2001 Swift/package
  files, SHA256 `051ee8bad445315deaa5f3b02e43e3dad7732c61790caf5b5f9884c8531e5577`,
  `/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r1.json`.
- Intermediate Release builds were not used for capacity claims. The final
  acceptance binaries are being rebuilt from this frozen source; staged capacity
  quality gates remain open.

## Frozen-binary capacity gate 1

- Final acceptance Release builds PASS: server 169.29 seconds; account 10.82
  seconds. Source inventory verified unchanged after both builds. Immutable
  artifacts: `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r1/manifest.json`.
  Server SHA256 `730ac6ff9ef51f63e5a0f40a2f0fbbb961bc8927fed41fe26ac9e38db7bc5cab`;
  account SHA256 `5fe1d9f49c81edac87c34614d87fea077386275ae8e528dac67786e5f73856bf`.
- 10k connections / 1000 messages per second scaled diagnostic quality PASS.
  Exactly 10000 authenticated and peak active; 12/12 reports exited zero;
  29988 sent and acknowledged (993.767 ACK/s); zero failed/workloadFailed,
  overflow, abandoned or queued-at-end; actual scenario drain PASS.
- Native TCP send and TCP-query recovery verified. Coverage proof PASS for
  all10000 connections. Common measured window 30.001 seconds. Foreground
  database witness checked10000 viewers: zero missing, behind or ahead.
- Owned services no longer live; owned PostgreSQL stop log confirms terminal
  cleanup. Original fixtures and quality/TTL/drain conditions unchanged.
- Evidence: `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r1/candidate/result.json`;
  this is a scaled diagnostic PASS, not formal 50k/5000 acceptance or isolated
  Registry causality. Gate2 (50k/1000) has now started with the same artifacts.

## Remaining Registry boundary integration

- Parallel owners are implementing subscription state, retired Writer lifecycle
  supervision, and complete authoritative position metrics. Sources are not
  integration-verified yet; no completion claim is made.
- Immutable r1 artifacts continue50k/1000. All50000 connections crossed the
  common warm barrier. This run cannot validate subsequent source changes.
- Six metrics HTTP timeouts in a live cycle are observation gaps, not proof of
  termination or deadlock. A bounded native stack sample is preserved at
  `/tmp/imv2-registry-refactor-50k1000-live-sample-20261003.txt`; sparse stacks
  are insufficient to attribute a dominant CPU hotspot.

## Frozen-binary capacity gate 2: FAIL

- Runner session76007 completed exit1; owned PostgreSQL stop log confirms
  stopped. Do not advance to5000 using this failed gate.
-50k/1000:89988 sent,89961 ACK,27 workload failures, all deferred TCP retry
  exhaustion; zero load-side overflow/abandoned/end queue. Coverage both scopes
  only775 connections: account46196/room42981 remained recovering.
-324 metrics requests:300 timed out,24 returned (node1 accounted18). Successful
  samples show demand age about9minutes and queued prepared proof expiry4061;
  root caps were respected but control roots took up to24.39s. This does not
  attribute delay to SQL, socket, actor scheduling, or synchronous scans.
- Load-side drained=true is not server actual-drain proof: five Gateway logs
  contain gateway_connection_shutdown drain_timeout. Quality remains failed.
- Host message-phase samples CPU busy78–94%; swap did not grow, memory pressure
  remained normal. PostgreSQL sampled longest statement/transaction about1.3s,
  no sampled sustained long lock chain. Messages median5.4–6.0s, SERVER_BUSY1143.
  Sampling gaps prevent node-wide or single-root-cause conclusions.
- Final boundary sources add subscription state, strict-C retired supervision,
  and authoritative position metrics; targeted integration test is running.
  r1 runtime evidence cannot validate these subsequent edits.

## Final Registry boundary verification

- Integrated V2ConnectionSubscriptionState; detach atomically removes paired
  indexes before async cleanup, preserves captured stream and mutation fences.
- Integrated V2GatewayLifecycleSupervisor exact(connection,lifecycle) receipts.
  Registry callback synchronously settles Supervisor then Directory, preserving
  strict C retention; no extra C+16 allowance or async handoff gap.
- Targeted Swift test PASS:7 tests,4 suites,0.759s; build88.07s. Covers real retired
  control writer drain, active/retired late Ready (two cases), subscription
  activation race, churn mutation cleanup, Presence stale scope isolation,
  concurrent device close, and exact position metrics. Terminal session4833
  exit0; `/tmp/imv2-registry-refactor-final-boundaries-tests-20261003.log`.
- Server boundary verifier PASS0exceptions; scoped diff whitespace check PASS.
- Remaining performance source audit finds repeated synchronous O(D) demand
  scans in pump (including filter/map/min allocation), plus worst-case O(KQ)
  scans/moves for prepared cohorts, K<=128/Q<=1024. These share Coordinator with
  query-return/output-settlement continuations. Short offer itself only awaits
  two actor hops and bounded5-slot acceptance; it does not await socket/SQL.
  Control root age is whole cohort age, not single-offer latency. This proves
  structural work/coupling, not its measured contribution to the failed gate.
- Completion remains unproven: failed50k quality/actual drain, observation gaps,
  and formal5000 gate outstanding. No repeat capacity run until next diagnostics
  can discriminate scheduler CPU versus provider/actor-hop delay.

## Bounded scheduling integration (verification in progress)

- Coalesced request ownership replaces synchronous whole-demand scans in
  callbacks. Single primary linked-node store and stable cursors, one1024 queue,
 128desired+128queued scan quantum, yielding full rounds; no shadow demand table.
- Prepared cohort scans at most128 entries across the whole root. Full-ledger
  class exchange drops displaced queued proof while retaining primary demand/H.
- Scheduler and original-deadline timer handles are joined, including shutdown.
- Fixed completed-span/scan counters and synchronous independent metrics route
  added; optional benchmark sampler preserves the original measurement gates.
- Targeted unified test session5146 exited1:17 tests, three tests failed.
  The failures exposed cross-stage proof cleanup and two obsolete scheduling
  assumptions; the other14 passed. Repair run session42217 exited1: Presence
  ownership and dynamic cohort coverage passed; duplicate-return assertions
  still observed concurrent legal position migration. Further isolated repair
  is in progress; no runtime capacity rerun started.
- Boundary verification PASS680files/75overrides/2557symbols/2685edges, forbidden0
  cross-target SCC0. Actual pipeline performance acceptance remains open.

## Current shutdown ownership audit

- Read-only audit found no cycle in the production Registry global shutdown
  path: Presence, Coordinator, retired supervision and active stream drain are
  joined concurrently; callbacks do not await that global shutdown.
- Outbound positions remain owned through operation and settlement callback;
  Presence results remain counted while settling; cancellation does not remove
  actual authorization returns or writer roots. Retired Supervisor settlement
  precedes Directory position release.
- This is source evidence, not an actual runtime-drain pass. Writer success
  represents EventLoop writeAndFlush enqueue under the existing contract, not
  remote receipt or flush Future completion. A provider that ignores cancel
  must finish before its actual position is released.
- A future writer callback must not await Registry global shutdown, which would
  await that writer. No such production entry was found in this audit.

## Proof and isolated-return repair verification

- Authorization failure now discards cached room and Presence proofs; only
  interest failure can preserve current independent authority. Original room
  observation time is a TTL start, not permission ordering against a denial.
- Added explicit Presence-denial regression: cache recorded while a real
  permission call is held, then denied; cache is removed and original retry
  timer performs another permission call without new input.
- Duplicate-return regression now waits for actual interest/control settlement
  while four query gates and three outbound gates remain held; exact ledger
  components stay unchanged after the duplicated callback.
- Repair run session63853 exited0:3 tests in2 suites PASS0.701s. Log:
  `/tmp/imv2-registry-refactor-proof-denial-repair-tests-20261003.log`. Earlier
  dynamic prepared-cohort coverage repair also passed in session42217.
- Benchmark syntax and scoped whitespace checks PASS. Latest sources frozen
  into r2 source inventory; release/runtime acceptance remains outstanding.

## r2 immutable acceptance artifacts

- Frozen source inventory:
  `/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r2.json`,
  2054 files, SHA256 c9f51fe4007836c886fb0c00cfffaf26660f40649e4caaa3dd8b7aa2f0e012ce.
- Both Release products built successfully and all inventoried files verified
  unchanged before/after builds. Server wall189.76s; Account wall15.18s.
  Binary identities: `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r2/manifest.json`.
- Candidate10k/1000 uses the original paired-policy fixture, original
  actor-realtime-scaled-diagnostic-1000 scenario and frozen common Loader.
  Independent recovery scheduling sampling enabled; no quality/load changes.
  Runner session77226 started; runtime result is pending. Do not interpret
  r1 quality results as validation of r2 scheduling/proof changes.

## r2 10k/1000 quality gate PASS

- Runner77226 exited0; owned PostgreSQL stop confirmed.29988 sent=ACK,
  997.990 ACK/s in30.002s common window; zero failed/workloadFailed,
  overflow/abandoned/end queue. Coverage10000 PASS; foreground witness10000
  viewers, missing/behind/ahead0. Six Gateway logs, zero drain_timeout.
- Fast scheduling sampler324 requests:312 successful and12 connection-refused
  during startup; no later timeout observed. Process-lifetime maxima across
  nodes: pump34.587ms, short offer34.122417ms, logical interest2005.713167ms,
  room provider430.741958ms, control cohort260.630416ms. These are elapsed,
  overlapping spans including startup, not CPU or pure SQL/RPC attribution.
- Evidence: `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r2/candidate/result.json`.
- Next original50k/1000 gate launched against the same frozen r2 binaries,
  original fixture/scenario/Loader and quality checks. Formal5000 not started.

## r2 live50k warmup diagnosis

- Runner18141 remained live; six Gateway active counts sum50000 before common
  warm barrier. Recovery desired counts near zero did not establish Loader
  warm completion. Source review found the unchanged workload ramp16 channels
  per second per partition:4167 channels need260 one-second intervals before
  room warmup check. It requires two room opens plus subscribed tail completion
  per connection, then writes ready files.
- All12 ready files appeared and original common barrier released at about
  329s since run-directory creation. No restart or load/ramp change.
- Source audit found no hidden whole-demand scan in128+128 scheduler passes.
  Remaining bounded candidate scans and shared coverage-lock contention are
  possible attribution points, not proven hot spots. Logical interest2s maximum
  cannot distinguish transport attempt deadline from coverage/callback waiting.
- Independent per-node metrics currently have no errors after first successful
  sample. Postbarrier workload quality and server drain remain pending.

## r2 50k/1000 gate FAIL — measurement separated from cleanup

- Runner18141 exited1 after a Loader workload guard; owned PostgreSQL stop
  confirmed. Four reports retained; the other eight partitions were cancelled.
  Do not use the partial result denominator for complete-window throughput.
- First failures were TCP_DEFERRED_RETRY_EXHAUSTED during rate1000 second50–78
  across all12 Loader logs. Four reports had9/11/11/9 original phase failures
  and guard failures9or11/7332. Their80s phase samples saw DEFERRED908/BUSY645,
  p50 send6.15–6.36s. Final3157 CONNECTION_CLOSED outcomes were subsequent
  shutdown effects, not the initial cause. Coverage/quality did not pass.
- Exact scenario: after common warm barrier comes180s checkpoint, then90s rate.
  An earlier commentary called checkpoint samples message-window data; corrected
  and offline phase analysis now uses the original durations. No scenario change.
- Actual failed measurement interval was barrier+180 through about+260s.
  Full samples15rounds/90nodes and fast39rounds/234nodes had zero timeout.
  No Gateway request error/warning or drain_timeout was observed in this run.
- Recovery ledger saturated at6144 across six nodes; final queued5413,
  returns727, selected4, outbound0. room desired peaked33332 and ended16969;
  oldest original demand78.44s. Prepared expiry0; outbound ages<=269ms,
  so socket retention is not the principal ledger occupant. Query providers
  averaged1.35–1.54s. Completed-span totals overlap and are not CPU attribution.
- Scheduler still examined about41.18M primary and15.41M queued entries in
  this interval. Bounded per-pass work alone did not prevent repeated full
  rounds: repeated primary scans are the next concrete scheduling correction.
- Send owner queued turns peaked465–701 and ended414–646 per node; one actual
  quota-key batch per node. Whole body averages278–295ms, connection acquire
 69–82ms. Database ordinary loan queues peaked15–28. PG blocked peak10,
  longest statement0.373s, mostly room activation fences. This establishes
  several pressure points, not a long SQL deadlock or single proven root cause.
- No5000 run. Further source work targets redundant primary scans and reviews
  quota-key transaction ownership; no pool/capacity/deadline/load relaxation.

## r3 source review and focused verification preparation

- Primary admission now distinguishes ordinary queued-work wakes from explicit
  fair admission rounds. A scalar refill flag preserves tail progress after
  successful Ready releases a position; it adds no mirrored demand queue.
- The 1100-scope success fixture uses authenticated ByteStream and actual
  enqueue permits, not OS TCP. Its one updated room's query head tracks the
  observed watermark16; the fixture no longer returns an inconsistent zero.
- Send-owner standby is admitted only after a predecessor reports an actual
  physical loan. The whole predecessor batch pins that loan across confirmed
  rollback isolation and scalar fallback; the standby awaits an exact quota
  permit before BEGIN. Existing roots/items/bytes/deadlines remain authoritative.
- Independent source review found no new resource cycle. A closed physical
  connection prevents further isolation/fallback; COMMIT-unknown results retain
  their classification. Individual caller cancellation of submitted work keeps
  existing actual-batch ownership; task shutdown/deadline can wake a standby.
- Root created a fresh owned disposable PostgreSQL cluster with distinct source
  and target databases for backend-PID evidence. No previous capacity cluster
  or baseline fixture is reused or modified. Source and test results remain
  unverified until the focused build/test actually finishes.

## r3 focused boundaries PASS

- First build failed on a misplaced owner-stage aggregation block in the
  non-owner snapshot aggregator. Removed that block; the owner aggregator still
  reports fixed stage counts only when every contributing owner supports them.
- Repaired focused invocation exited0: 10 tests in three suites, 11.965s test
  execution, 86.08s compilation, 110.34s whole invocation. Evidence:
  `/tmp/imv2-registry-refactor-r3-focused-tests-repair-20261003.log`.
- Disposable PostgreSQL was actually configured with distinct primary and
  secondary databases. Owner FIFO/budgets/deadline/cancellation tests executed
  their database fixtures. The new backend-PID test passed real rollback,
  recursive isolation and four scalar transactions with one backend identity.
- New standby success/shutdown cases passed: no acquisition before predecessor
  loan witness, no BEGIN before exact quota turn, no root/item release before
  actual standby release, and all stages/root/item/byte counts zero after drain.
- Recovery scheduler's false/true output cases and original timer/drain case
  passed; successful authenticated ByteStream enqueue drove all1100 Ready
  results and cleared demand without fresh input. This is not OS TCP evidence.
- Runtime-pressure route fixture passed fixed owner-stage rendering. Module
  boundary checker exited0 with zero migration exceptions.
- Frozen source inventory2055 files SHA256
  `4b27d43ac7cddab2330252cc38d14856abddff0c6c724be3201fa81a62c1af54`;
  source manifest is `/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r3.json`.
  Shared transaction deadline regression also exited0: one real PostgreSQL
  test, 5.116s execution, no rebuild. Evidence:
  `/tmp/imv2-registry-refactor-r3-transaction-deadline-tests-20261003.log`.
  Owned disposable PostgreSQL was then stopped. Capacity quality remains pending.

## r3 immutable release builds PASS; 10k/1000 started

- Gateway release build exited0, wall213.94s; Account release build exited0,
  wall16.26s. Both source inventories matched the frozen2055-file manifest
  before and after compilation. Logs use prefix
  `/tmp/imv2-registry-refactor-r3-release-`.
- Binaries and SHA256 records saved to
  `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r3/manifest.json`.
- Candidate10k/1000 launched with original paired-policy fixture, original
  scaled scenario, unchanged common Loader and quality checks. Loader SHA256
  verified before launch. Output:
  `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r3`.
- This run is pending; no50k or5000 gate is claimed. Old r2 capacity evidence
  does not validate the new r3 source.

## r3 10k/1000 protocol quality PASS

- Runner82959 exited0. 29988 sent and ACK, no failed/workloadFailed/overflow/
  abandoned/end queue; common30.004s window, ACK997.103/s. All10000 coverage
  witnesses passed; foreground missing/behind/ahead all zero. TCP/tcp_query and
  frozen common Loader remained verified. Owned PostgreSQL stopped.
- Recovery fast metrics had no errors after first successful node samples.
  Evidence: `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r3/candidate/result.json`.
- Loader drain passed, but the normal benchmark did not retain owned-service
  exit codes. Gateway warning-level logs lack shutdown success notices; absence
  of drain_timeout does not prove actual server drain. Do not claim that witness.
- Runner now saves a separate aggregate service-cleanup.json after actual
  waits, including forced kills and exit codes without argv/credentials. This
  adds post-run evidence, not changes to Loader, load, timing or quality gates.
  Python compilation and scoped whitespace checks passed. Future runs must
  inspect this artifact alongside protocol quality.

- Original50k/1000 candidate scenario launched on the same frozen r3 binaries.
  Retains original warm ramp,180s checkpoint,90s measurement and all capacity
  checks. Output `/tmp/imv2-registry-refactor-capacity-50k1000-20261003-r3`.
  Runner SHA recorded separately; actual result and service cleanup pending.
  Formal5000 remains gated on this run.

## Current completion audit while r3 capacity runs

- Independent read-only review of the design and current production entry
  points found no newly established structural gap: connection/subscription
  state, lease ownership, exact Presence query/result tickets, recovery and
  retired writer ownership are wired into Registry. Historical intermediate
  failures are not treated as current failures when later evidence supersedes
  them; optional future improvements do not expand this refactor's scope.
- Completion remains unproven. Current remaining acceptance is r3 original
  50k/1000 quality and owned-service cleanup, followed by formal50k/5000 paired
  baseline/candidate quality and throughput ratio>=0.8. Unit tests and10k
  protocol quality are supporting evidence only.
- Live run93547 revalidated via its execution handle. Six Gateway metrics
  show50000 active connections while the common Loader warm barrier remains
  pending; no duplicate run or shortened warm/checkpoint window is started.

## r3 50k/1000 FAIL with complete window and service cleanup

- Runner93547 exited1 after completing the original90.012s measurement and
  all12 reports. Sent89988, eventual ACK89970, workloadFailed18 (all terminal
  TCP_DEFERRED_RETRY_EXHAUSTED), no message queue overflow/abandonment/end queue.
  Coverage failed; foreground50000 witnesses had2066 behind committed head,
  zero missing/ahead. Measurement ACK931.307/s; eventual ACK is not substituted
  for measurement-window throughput. Loader drain passed, overall quality did
  not. No5000 run started; formal capacity remains gated on scaled quality.
- Separate service-cleanup.json reports all25 owned processes settled, zero
  forced kills and zero exit failures. Includes completed Loaders and owned
  services; it is process lifecycle evidence, not a per-stage task gauge.
  Owned PostgreSQL postmaster.pid absent after confirmed runner exit.
- Strict first80s comparison uses only samples inside each message window;
  sample endpoint intervals r2=73.5s/r3=74.6s, normalized per node. New cohort
  acceptance rose885.2/s to938.2/s, still below offered1000/s. r3 owner queue
  peaks by node619/271/246/375/137/373. Do not mix nearest-before intervals
  spanning checkpoint into these rates.
- Desired scans fell about496k/s to435k/s, but pump synchronous wall-span
  totals remain about486–502ms/s/node, not CPU attribution. Query provider
  averages increased to1.93–2.27s. Preborrow acquire averages139.6–154.2ms are
  mostly overlapped; pipeline stages were observed, not inferred from source.
- At strict measurement offset88.8s, room desired35707 includes recheck26231,
  while sample node0 has ledger1023/1024 and query4/4. Outbound53 across nodes
  is small relative to backlog; node0 queued oldest83.4s. Fast sampler has no
  errors after first successful node observations.
- Source diagnosis: every retry timer requests a full primary fair round;
  new recheck demands also request it; requests reset an unfinished round toD.
  Fair rounds bypass full-ledger pause whenever any lane has capacity, including
  free control while room-query slots are full. The r3 ordinary-pump correction
  therefore did not isolate eligibility by service class. Minimal correction is
  being integrated with fixed class masks and distinct queued/off-ledger retry
  deadlines, retaining1024 and4/4/4 and successful tail refill.
- Evidence: r3 candidate/result.json, candidate/service-cleanup.json,
  recovery-phase-analysis.json and
  `/tmp/imv2-registry-refactor-r2-r3-rate-window-comparison-20261003.json`.

## r4 class-aware admission source integrated; verification pending

- Fixed seven-class masks express pending/queued/fair admission hints, not
  permissions or extra demand ownership. Full-ledger scans require a missing
  queued class with a usable corresponding lane; hints are reclassified and
  stale/exhausted hints reconsidered on actual root count/census changes.
- Queued retry wakes only queued scheduling. At most seven original absolute
  off-ledger retry deadlines request class admission; no ID queue is added.
  Unfinished primary rounds retain their stable cursor; successful position
  release still refills the tail and stops when the ledger fills.
- Fair exchange uses normalized admission class, so a hint-only control scope
  cannot be mistaken for raw roomAuthorization query work. Existing generation,
  authorization deadline,1024 ledger and4/4/4 remain in force.
- Existing successful tail test now first completes a warm real Ready scope,
  fills query4 and ledger, then repeats that old scope's recheck heads. It
  requires zero desired scans while blocked and eventual1102 Ready across1101
  rooms after original gates release. Existing queued-retry test requires zero
  primary scans. A focused selection also covers expired hint lane transition,
  presence/control independence, warm queries during cold interests, prepared
  fairness and exact authorization return ownership. No owner SQL change.
- Only Coordinator and scheduler fixture changed; r3 owner audit recommends
  deferring a narrow duplicate-timeout SQL reduction until scheduler effect is
  measured. Audit at `/tmp/imv2-registry-refactor-r3-owner-stage-audit-20261003.md`.
  The focused selection completed with failures; no new capacity run started.

## r4 focused regression evidence and followup

- `/tmp/imv2-registry-refactor-r4-scheduler-class-tests-20261003.log`:
  compilation completed in85.62s; seven functions across three suites ran
  in9.059s and reported four issues. The authorization-return capacity/generation
  test and warm-query/cold-interest independence test timed out. Both tail-test
  parameters observed1025 desired visits after existing head updates, where the
  test requires no desired visits with the actual query lane saturated.
- Prepared-cohort fairness, expired-hint lane selection, presence/control
  independence and the owned retry/shutdown test passed in that selection.
  This does not establish scheduler acceptance.
- Source followup identified two separate progress gaps: a remaining demand
  can lose its queue position when an old actual task refuses requeue and its
  terminal does not requeue the exact scope; a new fair search can reuse a
  paused round length which excludes subsequently appended scopes. Pending
  corrections must preserve exact return-ticket transfers and must not use a
  full-demand search to compensate for the first gap.
- Independent source review found a stale queued-class census path for the
  first head-update scan: dispatch records interest before removing its queued
  node; a partial result requeues query-ready work while an unfinished census
  keeps its old OR mask. The published mask can then suppress missing-class
  admission until an unrelated subsequent pump starts a fresh census. That
  search can traverse1024 represented nodes before reaching the first tail.
  This is a source-established path; the correction still requires the original
  deterministic assertion to pass.
- No timeout, capacity, proof deadline or load-quality gate has been relaxed.
  Only affected checks will be rerun after the scheduler source is frozen.

## r4 first repair selection: partial progress, acceptance still open

- `/tmp/imv2-registry-refactor-r4-scheduler-class-tests-repair-20261003.log`
  exited1: compile43.47s, nine functions in three suites ran19.386s, three
  issues. Warm room query with four cold interests now passes. The successful
  output tail parameter passes its original zero-extra-scan and full Ready
  assertions. The refused output tail parameter times out; without its exact
  call-site evidence its scan assertion cannot be considered verified.
- Authorization-return capacity/generation still times out, and Presence
  observation/control independence now times out. Exact timeout stage diagnostics
  are being added to those three failed paths before further production changes.
  Time limits and success conditions remain unchanged.
- Prepared fairness, refused Ready original-proof reuse, original authorization
  expiry, expired-hint lane transition and owned retry/real shutdown pass in
  this selection. Server boundaries pass with zero migration exceptions.
- Coordinator SHA25658f3af77029c8b3f94ddd4b261ffc69104eb54129335ca3211c3d035cd3c92d6;
  ownership fixture SHA256843e16aa2e0b5a91edc05db00d34dba98bd74295d8391e2e3a0d57992c5a8573
  matched before and after the run. No release or capacity result is claimed
  for this source.

## r4 exact timeout diagnostics

- Diagnostics-only selection, unchanged Coordinator SHA above:
  `/tmp/imv2-registry-refactor-r4-scheduler-timeout-diagnostics-20261003.log`,
  compile28.09s, three functions ran18.201s, exit1. Original deadlines and
  predicates remain unchanged; extra issues report the precise timeout state.
- Account failed specifically waiting for its Ready writer: desired1033,
  queued1020, four actual authorization roots, positions1024, interest/control
  zero and no outbound ticket. Candidate exchange must remain possible when
  a primary round outlasts its shorter queued census; current exchange uses
  only the pass-local candidate window. Source correction is pending.
- Refused-output tail passed its original zero-extra-scan assertion, then
  failed at line89 waiting for the previously installed tail after releaseAll:
  seen1024, provider calls14 and no held calls; query roots zero, control roots
  four, positions1024, pending room-interest bit and queued census at
  room-authorization. Successful-output parameter passes. This is tail
  starvation under retained retry positions, not a blocked provider gate.
- Presence timeout is specifically the final typing drain predicate: four
  actual presence preparations held, interest/control zero, but one queued
  typing retry. The fixture supplies neither a typing coverage confirmation
  nor an authenticated typing writer. Precise retry now retains that refused
  work rather than losing it. A corrected fixture must prove actual accepted
  typing Ready with those four preparations still held; queued/control/query
  predicates and the original two-second bound must remain intact.

## r4 victim-window correction and failed-check repair passed

- Fair primary search can outlast the shorter queued census. While that exact
  search is still active and has an available lane, the exhausted Q cursor
  continues to supply a fresh bounded candidate window; D cursor/remaining is
  not restarted. Only queued positions can be exchanged. Actual authorization
  returns, selected handoffs and outbound tickets are never exchange victims.
- Typing fixture now has exact coverage, real hello/authentication and a scoped
  writer which counts only actual successful enqueue of typing Ready. It keeps
  the four real Presence gates, queued/control/query predicates and two-second
  deadline, with actual drain on both success and failure.
- `/tmp/imv2-registry-refactor-r4-victim-window-tests-20261003.log`, exit0:
  compile29.62s, three functions across three suites ran4.521s. Authorization
  return capacity/generation passed; Presence/control passed; both accepted and
  refused output tail parameters passed their original zero-extra-scan and
  progress assertions. Runtime capacity acceptance remains open.
- Coordinator SHA256ad685f43ab06b9d8c5af0aff0388ac904c3d9a7e9de00c0f4245905c230e1cdf;
  coordinator fixture SHA25687a6885db8d8fcd5c087009468761b8faf44914887c39cfee6e4e791f7337970.
- r4 immutable source inventory contains2055 files, digest
  26e0cd2e097c91afac52bc7113c9145fd31efa1772445bd4c97a13d3af7a7960
  (`/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r4.json`).
  Release builds completed with source checks before and after each product:
  Gateway176.80s and Account15.02s, both exit0. Copied immutable artifacts at
  `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r4/manifest.json`.
  Gateway SHA2567ef0c4a5adbe36b73156d740ca5dd84834245d67f1c1ffad6f20a364182b7c98;
  Account SHA256923e7d02c2350b4f21a223490454d922d94654ccdad1b000985377627e270cc0.
- Original10k/1000 candidate gate completed at
  `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r4`, with original
  common Loader and independent recovery scheduling samples. Terminal exit0;
  all29988 sent messages acknowledged, workload failures/overflow/abandoned/end
  queue/heartbeat misses zero. Coverage proof10000 passed; foreground10000
  checked with missing/behind/ahead zero. Common30.008s window passed,
  measurement ACK998.816/s, Loader drain and quality passed.
- Separate `candidate/service-cleanup.json`:25 tracked processes settled,
  all exit0, zero forced kills and exit failures. This is process lifecycle
  evidence, not an assertion of every stage's zero gauge.
- Original50k/1000 candidate gate now running at
  `/tmp/imv2-registry-refactor-capacity-50k1000-20261003-r4` with the same frozen
  r4 artifacts. No5000 gate has started; no50k result is claimed yet.
- Independent strict10k comparison at
  `/tmp/imv2-10k-r3-r4-strict-audit-20261003.md` and matchingJSON: endpoints'
  complete sampling envelopes lie inside each common30s message window.
  Desired visits123703 ->0; queued visit rate86084 ->98053/s (+13.9%).
  Pump mean0.1040 ->0.1410ms, queued oldest sampled peak5.89 ->7.62s;
  overlapping wall spans are not CPU measurements. Both run quality gates pass.
  This supports removal of repeated primary discovery in10k, not an overall
  scheduler cost improvement or any50k capacity inference. Source remains
  frozen during the ongoing50k test for attribution.
- Final independent r4 source audit found no newly established ownership gap:
  exact taskID terminal/return transfer, original proof deadline, generation/H
  fences, bounded queued-only exchange and owned shutdown handles remain intact.
  Record: `/tmp/imv2-registry-refactor-r4-ownership-completion-audit-20261003.md`.
- Additional completed10k full-run metric evidence (including warm and cleanup,
  not the strict30s performance window):126 node snapshots satisfy queued +
  authorization returns + selected handoff + outbound == occupied, each<=1024;
  all actual lanes and permission attempts<=4. Last six nodes show all measured
  recovery positions/root counts and retired-work gauges zero. Retired work was
  unexercised in these runtime samples and still relies on its gated regressions.
  This strengthens instrumented drain evidence without replacing pending50k
  and formal5000 acceptance.

### r4 completed 50k/1000: send passes, recovery quality fails

- The previously running candidate gate is now terminal, exit1, at
  `/tmp/imv2-registry-refactor-capacity-50k1000-20261003-r4`. Source and binaries
  remained frozen throughout. All89988 messages were acknowledged; workload
  failures, overflow, abandoned messages, end queue and heartbeat misses were
  zero. Six busy rejections were retried successfully. The original89.995s
  measurement window passed, measurement ACK981.261/s.
- Coverage proof failed; foreground checked50000 with missing0, behind1654,
  ahead0. Loader drain passed. Therefore the candidate is not accepted and no
  formal5000 run follows this result. Process cleanup independently reports
  all25 tracked processes settled with exit0 and no forced kills. The final
  metrics sample still has occupied recovery positions; it is not evidence of
  shutdown-zero gauges.
- Strict first80s six-node comparison: desired visits429182 ->62363/s (-85.5%),
  queued visits274868 ->447984/s (+63.0%), pump completed mean0.783 ->0.784ms.
  Room-provider mean1848 ->1331ms includes callee queue and callback, not pure
  SQL/RPC. All six ledgers remain saturated near1024/node and oldest queued
  snapshot age is82.95s. These visits and overlapping wall spans are not CPU
  attribution. See `/tmp/imv2-50k-r3-r4-strict-audit-20261003.md` and JSON.
- Tail analysis:1651 behind by one message,3 by two;1626 had not received the
  latest high watermark and28 had received it but were still pulling.1634
  lagging clients had Ready for an older watermark, which does not prove latest
  delivery. Earliest final cursor snapshot was12.546s after all rate windows
  ended, after actual send drain and the original10s hold. Final ACK/DB head
  counts agree; report/head snapshots are non-atomic and cannot exclude every
  individual timing race. See
  `/tmp/imv2-registry-refactor-r4-owner-and-tail-audit-20261003.md`.
- Current scheduler still rediscovers queued class membership by whole-Q census
  and sometimes searches primary demands for fair admission. A128-item quantum
  bounds one isolation fragment, not whole-round work. Event-maintained class,
  placement and deadline indices are the next implementation; this record does
  not claim they are complete or that scans alone explain all remaining delay.

### r5 event-maintained scheduling indices: implementation and focused checks

- `V2RecoveryOrderedStore` now has one value-owning node with category,
  placement and eligible FIFO links plus an exact updateable deadline-heap
  index. Fixed seven classes and three placements are metadata on that node;
  there is no separate copied-demand queue. Future queued nodes remain eligible
  exchange victims; actual owned nodes are absent from selection links/heap.
- Coordinator normal pump no longer performs a full queued census or primary
  refill/fair search. State mutations synchronously maintain classifications;
  due keys are processed in bounded cohorts and dispatch still validates exact
  generation, coverage and original proof deadline. The unchanged low-frequency
  full metrics snapshot can traverse demands; fast scheduling telemetry does
  not access node storage.
- New helper regressions cover FIFO-preserving ordinary updates, future victim
  selection, actual-owner exclusion, replacement/removal of exact heap entries
  and bounded500-key due processing. Existing1100-scope tail regression now
  also requires repeated old H updates to add no queued visits, in addition to
  no desired visits and original successful/refused real-output gates.
- First compile exposed unqualified min/max resolution in the Sequence helper;
  corrected only to Swift.min/Swift.max. Repaired compile completed78.72s.
  `/tmp/imv2-registry-refactor-r5-index-tests-repair-20261003.log` is terminal
  exit1:19 selected tests in four suites,18 passed in0.955s. The single failing
  authorization-return fixture immediately samples an aggregate of query and
  interest return tickets while successor interest may be admitted concurrently;
  its next snapshot satisfies the original reserved3 assertion. A targeted
  stage-synchronization repair and rerun are still required, not yet accepted.
- Server boundary check passed with zero migration exceptions. Initial changed
  source copies and compile repair are preserved at
  `/tmp/imv2-registry-refactor-r5-index-source-20261003`. No r5 release artifacts
  or capacity result exist yet; r4's end-to-end failure remains authoritative.
- The single failed fixture now waits for the successor interest provider's
  completed counter to advance and actual interest to become zero, using the
  existing3s bound. It does not wait on reserved count as a passing condition;
  original reserved3, held-query4, original capacity and no-old-H9 assertions
  remain. No production code changed for this repair. Targeted rerun at
  `/tmp/imv2-registry-refactor-r5-index-return-test-20261003.log` is exit0:
  compile29.22s, one test0.848s. Other18 tests passed in the prior selection.
- Final boundary check again passed with zero migration exceptions. r5 release
  build is now running with immutable2056-file source inventory digest
  034e10412ae428647e9a168ad50a94dd3d0473ef5f3cc66531f9e3f75d8c8fa9,
  `/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r5.json`.
  Build helper checks the inventory before/after each product and preserves
  separate r5 binaries. Build completion and capacity acceptance remain open.
- r5 release build completed, source checks passed before and after both
  products:Gateway183.97s,Account14.82s,exit0. Artifact manifest:
  `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r5/manifest.json`;
  GatewaySHA256d9d86371f6b33579f6f80c594995f2c6c852b449b1b8a64e9878aa806f436a89,
  AccountSHA2567949a690556618c0465f0a8d07c3a448b05336266d8fc21a41f08919212135f4.
  Common LoaderSHA25615d76d405811d070863803db17d0f1a03655a9244e94f027f246e75a8c7f17c9
  remains unchanged. Original10k/1000 now running at
  `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r5`.
- Independent frozen-source ownership audit:
  `/tmp/imv2-registry-refactor-r5-index-ownership-audit-20261003.md`. It found
  no newly established gap in position, actual task, proof/generation or shutdown
  ownership. Complete metrics still traverses demands, at5s sampling in the
  benchmark; production scrape frequency is not forcibly limited. Independent
  scheduling metrics renders a fixed snapshot and does not perform that traversal.
  This source audit does not prove runtime capacity acceptance.
- Original r5 candidate10k/1000 completed exit0:29988sent=ACK, zero workload
  failures/overflow/abandoned/end queue/heartbeat misses. Coverage10000 passed;
  foreground10000 had missing/behind/ahead0. Common30.006s measurement window
  passed, measurement ACK994.783/s, Loader drain and quality passed. Separate
  cleanup reports all25 tracked processes settled, exit0, zero forced kills;
  stage-zero gauges still require their own sampled evidence. Offline phase
  analysis records55 rows, six nodes, no metric errors after first success.
- Original r5 candidate50k/1000 has started at
  `/tmp/imv2-registry-refactor-capacity-50k1000-20261003-r5`, same frozen
  binaries/common Loader and original scenario. No50k outcome is claimed and
  no formal5000 gate has begun.
- Strict r4→r5 10k audit at
  `/tmp/imv2-10k-r4-r5-strict-audit-20261003.md` and JSON uses15 full six-node
  scheduler rows whose complete collection envelopes fall inside each30s rate
  window; delta spans28.327/28.429s. Queued node accesses98053 ->1458/s (-98.5%),
  desired accesses0 both. r5 counts exact indexed visits, not full scans or
  unique scopes. Pump completed mean0.14095 ->0.03336ms (-76.3%); overlapping
  synchronous wall totals12676 ->2521ms are not CPU measurements. Provider
  mean37.95 ->41.17ms gives no provider improvement claim.
- Six complete gauge rows in those windows: per-node ledger peak22 ->29,
  oldest queued snapshot7.624 ->5.679s, query roots/provider attempts<=4. Last
  r5 six-node sample at barrier+39.208..39.222s actually shows recovery ledger,
  roots/provider/scopes, Presence and retired gauges zero. This is sampled drain
  evidence independent of process cleanup; it does not validate50k capacity.
- r5 original50k/1000 is now terminal exit1. All89988sent messages were ACKed;
  workload failures, overflow, abandoned/end queue and heartbeat misses0.
  Fifty-one busy rejections retried successfully. Original90.005s window
  passed, measurement ACK975.861/s. Coverage proof50000 failed; foreground
 50000 checked with missing0, behind1994, ahead0. Loader drain passed. This
  fails end-to-end acceptance and is worse than r4's1654 final lagging clients;
  reduced10k scheduling work cannot be used to claim recovery performance fixed.
- Separate r5 service cleanup:25 processes settled, all exit0, forced kills0;
  this does not prove uncaptured final stage-zero gauges. Offline phase analysis
  saved284 rows, six nodes, no errors after first successful node sample.
  Source remained frozen throughout. No formal5000 run is permitted by this
  result. Strict r4/r5 provider/cohort and tail delivery audits are pending;
  no new bottleneck cause or production fix is claimed before those audits.
- Initial r5 tail aggregation:1980 of1994 lagging viewers have announced H
  below final committed head with no pull in flight;14 know the latest H and
  are still pulling.1987 have Ready/coverage pass for an older watermark.
  Final live probes occur13.866..14.370s after the latest phase end, so the
  original send drain and10s hold took effect. Final ACK and DB head totals
  agree. Non-atomic per-client/head snapshots remain an attribution limitation.
- Initial full-rate provider/cohort comparison (unequal valid sampled spans,
  not strict paired CPU attribution):r5 authorization99875scopes/1211roots,
  mean82.47keys/root vs r4 mean86.73;host cohort10.67 vs10.33keys/call. This
  does not support microbatch splitting as the dominant tail cause. Remote
  host caller and position resolution wall spans increased; exact paired
  windows and tail/provider audits remain pending. No batch/priority/TTL
  production changes have been made based on this provisional comparison.
- Completed strict r4→r5 first80s audit:
  `/tmp/imv2-50k-r4-r5-strict-audit-20261003.md` and JSON. All counter endpoint
  envelopes lie inside each configured barrier+180..260s. Desired visits62363
  ->341/s, queued visits447984 ->1898/s (both >99% reduction); pump mean0.784
  ->0.213ms. Query-provider completed mean1331 ->1680ms and completions17.52
  ->13.71/s; authorization scope starts1324 ->1137/s. Query roots and ledgers
  remain saturated. Broad spans include queueing and overlap, not pure SQL,
  RPC or CPU. The evidence supports lower scheduler cost, not solved recovery.
- Further source review found `V2RoomDirectory.remember/invalidate` linearly
  update cacheOrder using removeAll, and full cache eviction uses removeFirst.
  This is a definite per-event O(cache-size) cost, without runtime attribution
  proving it causes the increased resolution wait. The next implementation
  replaces this with exact ordered-node maintenance preserving capacity/token
  invalidation/eviction semantics. Separately, original design§8 Ready rejection
  reason observability remains incomplete and is being specified for completion.
  No cohort/priority/TTL/capacity changes are justified by the current audit.

### r6 cache maintenance and original Ready rejection observability

- Directory now owns a single `V2RoomLocationCache` node map. Each node holds
  value and eviction-order links. Successful remember moves the exact node to
  newest; reads preserve order; removal and oldest eviction do not traverse all
  cached rooms. Original20000 capacity, exact token/owner/revision invalidation,
  cold-first resolution, global four physical host slots and actual drain are
  unchanged. This removes a definite linear cost, not a proven cause of r5 lag.
- Ready rejection observability adds eight fixed reasons:permission_expired,
  permission_missing,generation_invalid,head_unsatisfied,coverage_changed,
  closed,recovering,enqueue_refused. Counts are failed checks/suppressed
  transitions, not distinct failed operations or socket-capacity failures.
  Fixed global Atomic counters remain safe under existing ByteStream outer
  fences and account for retained retries. They never take the timing mutex or
  acquire enqueue fences; snapshots are not atomic across reasons. Original
  validator order, proof deadlines and actual enqueue decisions remain.
- Changed source copies are preserved at
  `/tmp/imv2-registry-refactor-r6-cache-observation-source-20261003`. Server
  boundary check passed with zero exceptions. Unified affected selection:
  `/tmp/imv2-registry-refactor-r6-cache-observation-tests-20261003.log`,exit1,
  compile98.64s. Directory12 functions/two suites passed0.141s, including three
  new cache cases plus actual warm/cold, global slots/cancel, ABA and eviction.
  Four pre-existing Ready/metrics tests passed; the one new Ready permit
  classifier fixture failed because valid Ready preparation is not established.
  A targeted fixture repair is pending; production safety checks are not relaxed.
  No r6 release artifacts or capacity result exist yet.
- Failed new Ready fixture was repaired without production changes:it now uses
  a truly authenticated ByteStream, waits for actual first Room Ready0 plus
  completed scope/task/position settlement, then gates its next real query.
  H6 vs required7 rejects; recorded H7 permits exactly one synchronous enqueue
  callback. Original stale generation/TTL/closed and no-generic-H-counter checks
  remain. Every failure path releases the gate and joins actual cleanup.
  `/tmp/imv2-registry-refactor-r6-ready-rejection-test-repair-20261003.log` exit0,
  compile25.49s,test0.005s. Other16 affected functions passed the prior unified
  selection; no full suite repeat was needed for this test-only repair.
- Final boundary check again passed with zero exceptions. r6 source now frozen
  at2058 files,digest13520be7ad1bc382dfcf5dbabc325385ba96c8993aa9f0e7aff1fbf889d75672,
  `/tmp/imv2-registry-refactor-acceptance-source-manifest-20261003-r6.json`.
  Release build is running via the unchanged immutable artifact helper; no
  capacity result or performance improvement is claimed for r6 yet.
- r6 release build completed with unchanged source checks before/after both
  products:Gateway191.22s,Account17.05s,exit0. Manifest:
  `/tmp/imv2-registry-refactor-acceptance-binaries-20261003-r6/manifest.json`;
  GatewaySHA256fa0db2e3937a995d4669690469176397848d94f351290aba62a5420dfe522b65,
  AccountSHA25660a0e933406ed580d9674fb952af47e799953cb9160eac39efef027a0e418346.
  Original candidate10k/1000 is running at
  `/tmp/imv2-registry-refactor-capacity-10k1000-20261003-r6`, with the unchanged
  common Loader/scenario and quality gates. No capacity outcome is claimed yet.
- r6 original candidate10k/1000 completed exit0:29988sent=ACK, workload failures,
  overflow, abandoned/end queue and heartbeat misses0. Coverage10000 passed;
  foreground10000 missing/behind/ahead0, original30.001s window passed,
  measurement ACK992.566/s, Loader drain and quality passed. Separate cleanup
  reports25 processes settled/exit0,zero forced kills. Phase analysis captures54
  fast rows,six nodes,no errors after first successful sample. All eight Ready
  reason series were observed on all six nodes; cumulative initial values must
  not be interpreted as phase-only failures or socket-capacity exhaustion.
- r6 original50k/1000 now running at
  `/tmp/imv2-registry-refactor-capacity-50k1000-20261003-r6`, same frozen
  artifacts/common Loader/original scenario. No50k result is available and no
  formal5000 run has started. r5's failed end-to-end result remains recorded.
- The r6 original50k attempt is now terminal exit1 during connection ramp,
  before any common scenario barrier or messages:12649 authenticated,23
  failures,0 sent/ACK. Four Loader reports ended14:51:36 with connection reset
  errno54 and existing connection-failure guard triggered. This is an incomplete
  workload, not a completed50k capacity measurement; no formal5000 follows it.
  Separate cleanup settled with zero forced kills;12 Loader exit failures or
  cancellation exits are recorded rather than claimed all-exit0.
- Startup-abort audit:`/tmp/imv2-r6-ramp-abort-audit-20261003.md`. Later
  SessionError14:51:37–38 and SWIM suspect/dead after14:51:38 cannot be inverted
  as causes of already finished Loader failure reports. Database rejected-loan
  counts also include teardown cancellation and lack reason labels. Source-port
  preflight found no owned tuples and allocated nonoverlapping same-target
  ranges; no observed OOM/port/FD exhaustion error proves a resource cause.
  Actual FD occupancy was not captured. No environmental-transient explanation
  or rerun success is claimed from these observations.
- Next required diagnostics preserve handling behavior:fixed SessionError branch
  codes and safe numeric socket errno, plus a closed typed loan-error-code
  interface without Application→Infrastructure dependency. Error descriptions,
  addresses,payloads and credentials remain excluded. No capacity/TTL/Loader
  or connection-failure guard changes are authorized by this incomplete run.
- r5→r6 strict10k report:`/tmp/imv2-10k-r5-r6-strict-audit-20261003.md`/JSON.
  Both quality gates pass; r6 gives no overall-delay improvement evidence and
  there were no completed cold resolutions in its strict message window.
  Ready counters are failed checks (possibly overlapping), not distinct failed
  attempts; enqueue_refused637 must not be attributed to socket capacity.

### Partition-stream replacement: implementation in progress, not accepted

- User authorized the replacement architecture and parallel GPT-6.1 Sol/low
  implementation. Root owns integration, builds, test runs and capacity gates;
  agents own source changes only. Existing unrelated work remains intact.
- Scope remains the entire replacement: committed outbox/journal, fenced
  source-local publisher, partition replay/snapshot cuts, Gateway shared head
  and versioned authorization, fixed subscription baselines, independent
  device cursors/writers, revocation and final-hint anti-entropy. Indexed legacy
  recovery and unchanged budgets are retained until these semantics are proven.
- Initial source changes add journal contracts/PostgreSQL storage/SQL extension
  and a bounded publisher. Source-local leases are distinct from routing leases:
  a maintenance-database routing lease cannot fence a transaction on a different
  source database. The extension is not yet installed or wired into production.
- Live body ingress now precedes recovery control handoff, retaining existing
  transaction audience, membership and socket fences. Registry's new handoff
  currently delegates to legacy permission-fenced recovery; this is an explicit
  integration gap, not evidence that per-head recovery queries are eliminated.
- Account shared-head APIs require exact owner, permission and viewer versions;
  absent/gapped projections retain the authoritative fallback. Real control-feed
  installation, remote checkpoint protocol and removal of periodic permission
  reads remain pending. Journal delivery cannot checkpoint RPC admission or
  socket completion as shared-state application.
- Client installation snapshots retain a fixed baseline and distinguish durable
  applied-through from installed state. Server repeated Ready for the same
  coverage keeps its original baseline; later H still requires an actual hint.
  Targeted client build completed in10.64s and3 selected tests passed in0.003s:
  baseline/hints, coverage generation/revision and account coverage limit.
  Log:`/tmp/imv2-partition-stream-client-baseline-tests-20261003.log`.
- PostgreSQL journal behavior, server integration and capacity are unverified.
  No new load run has started. Required acceptance remains10k/1000,50k/1000,
  then formal5000 with actual final durable cursors and original observation
  windows. Fixed-baseline completion cannot replace final freshness.
- First server build completed92.29s; four selected tests passed0.006s:
  fixed Ready baseline after newer actual hint, exact Account permission
  projection/gap, uncertain committed append replay, and projection failure
  retaining replay responsibility. No whole-suite repeat or load was run.
  Log:`/tmp/imv2-partition-stream-server-focused-tests-20261003.log`.
- An independently created disposable native PostgreSQL16 database successfully
  installed the complete schema and extension. A real source-local lease test
  passed0.839s using the built tests: idempotent claim, renewal, takeover after
  expiry, rejection of the old publisher and protection from late release.
  Log:`/tmp/imv2-partition-journal-local-lease-tests-20261003.log`.
  This proves local fencing only, not journal append/replay/trim or runtime
  control delivery. Those gates and production composition remain pending.
- Client reconnect test additionally passed both overlapping/non-overlapping
  cases using skip-build; baseline resets on physical reconnection.
- First real journal behavior run compiled74.34s: wire/SQL hash compatibility
  and wrong actual-apply receipt rejection passed, three database behavior tests
  failed. A minimal PostgreSQL reproduction identified reserved `offset` in
  the append expression; renamed it `journal_ordinal`. The four affected
  database scenarios are being rerun; no append/replay success is claimed yet.
  Logs:`/tmp/imv2-partition-journal-behavior-tests-20261003.log` and
  `/tmp/imv2-partition-journal-behavior-tests-20261003-r2.log`.
- Source now also includes a bounded filtered-stream receiver and wire contract:
  database incarnation and local publisher lease differ from routing ownership;
  explicit skip ranges advance actual applied position, control gaps fail
  closed, and only a trusted complete snapshot at an exact cut restores grants.
  Account's configured shared projection path uses committed head without
  state SQL; production configuration and actual socket fence remain pending.
- After fixing the syntax error, append/replay/trim and rollback tests passed;
  the late-commit test exposed another concrete lock coupling: source inserts
  hold KEY SHARE on the foreign-key partition row, while the publisher's
  FOR UPDATE waited for invisible sources. Changed only the counter lock to
  FOR NO KEY UPDATE, preserving allocator exclusion. All four real database
  scenarios then passed2.971s after incremental build10.60s. This concerns the
  new journal and does not establish the cause of previous capacity failures.
  Log:`/tmp/imv2-partition-journal-behavior-tests-20261003-r3.log`.
- Four shared-projection/Account tests passed0.001s using skip-build: filtered
  range and shared head, control-gap/snapshot completeness, stale source lease
  with unchanged routing, and actual Account wake without state SQL. This is
  configured-component evidence, not production wire or socket-fence evidence.
  Log:`/tmp/imv2-partition-shared-projection-tests-20261003.log`.


### Shared control / coalesced head revision (2026-10-03, integration incomplete)

The latest architecture separates high-frequency room H from reliable permission
control. Immutable business message rows now dirty one per-room head record;
head publication does not allocate journal sequences or copy message bodies.
Dirty acknowledgement compares revision, H, owner and control version in a
source-lease-fenced transaction, so a concurrent newer change remains pending.
Control journal replay still owns continuous checkpoints. Control dedup retains
one version floor per topic, rather than a permanent receipt per event.

The shared receiver uses explicit authoritative control floors (including a
trusted initial floor of zero), filters grants to locally requested viewers,
and rejects newer self-asserted grants until trusted snapshot recovery. Older
pending controls cannot resurrect snapshot-revoked viewers. Independent heads
return headsApplied without any control checkpoint. Normal head application
uses touched-room staging and incremental capacity counts, avoiding a full
partition/viewer scan per message.

GatewayJournalProjectionReceiver is a trusted composition boundary: installed
service identity, exact lease/routing/session/interest generation and conservative
local monotonic expiry are required. Cold snapshots must equal a locally
pre-authorized authoritative result. Socket enqueue has a synchronous grant gate
with the same receiver -> projection lock order as revoke/application. Wire Date
cannot renew authority. This component is not yet installed in production Runtime.

Publisher now retains at most four actual partition tasks, independent apply
checkpoints, fair claim rotation and conservative source-local monotonic expiry.
A slow callback does not impose a whole-task-group barrier. Dirty head application
must succeed before source CAS ACK; H/revision never advances control checkpoints.
Discovery queries are still sequential by source and need bounded isolation in
production composition.

Remaining acceptance work: production source identity mapping to authenticated
logical shard access; subscription/watch plus authoritative baseline barrier;
recipient-specific control/head delivery and actual writer hookup; room policy
versus per-member generations; removing old H recovery and 30-second permission
queries only after the replacement is active; schema readiness and lifecycle;
last-hint-loss repair; frozen 10k/1000 -> 50k/1000 -> formal 5000 capacity ladder.
Component tests cannot prove those requirements.

Focused verification is in progress in
/tmp/imv2-shared-head-control-focused-20261003-r3.log. The first two builds found
Swift Testing sendable-macro argument failures and an extra fixture parameter;
these were corrected without weakening Sendable API contracts. No capacity run
has been started for this revision.

Focused verification completed: r3 compiled in 56.91 seconds and executed 24
server tests, with one failing publisher deadline test; the signed Actor RPC
commit test passed separately. Real PostgreSQL control/dirty-head tests passed.
The failure exposed a real liveness bug: after a committed append consumed the
outbox, expiry cleanup erased pending replay responsibility. Expired/failed
renewals now retain checkpoint and needsReplay; re-claim discovers retained
responsibility independently of outbox rows. The deadline assertion was not
weakened and now also checks that the consumed outbox is empty. A new trusted
receiver regression checks that renewal after a local authority gap requires a
fresh authoritative snapshot. r4 re-ran the affected publisher and receiver
suites: 11 tests passed, terminal exit 0; no capacity tests or services started.
Both test process handles are terminal. Runtime replacement remains incomplete.


### Runtime interfaces and actual writer integration (2026-10-03, not accepted)

Configured Registry now uses the shared room H and one in-flight/one latest
per-stream hint slot. Ordinary known/current heads bypass per-connection recovery
and legacy authorization TTL rechecks. Unknown/failed writes retain maximum H for
cold recovery. Direct/group body paths preserve transaction audience and global
group revision in addition to current shared viewer grants. NIO FIFO entries
carry the captured source/fence/lifecycle permit to actual channel.write;
coalescing cannot bypass per-frame revocation. Account notifications carry viewer
join revision and a scoped writer permit. Author presentation supplements remain
inside the same actual authorized body enqueue. Runtime is not yet configuring
this replacement, so this is actual configured-writer evidence, not deployed
capacity evidence.

ShardService exposes complete acknowledged recipient interests. Fanout uses
partition session revision, not one arbitrary topic generation, with independent
recipient retry checkpoints, filtered sequence ranges and typed real receipts.
The current source callback still waits for all current recipients; independent
durable consumers are required to remove the single-partition slow-recipient
barrier. Non-room controls explicitly fail without a trusted implementation.

Source catalog binds logical aliases to persistent DB identity/incarnation,
chooses one canonical source per physical schema, and queries exact requested
room/user pairs instead of a Cartesian product. Repeatable installation is
transactional and serialized with a schema-specific advisory lock. Readiness is
read-only and rejects disabled capture triggers or missing discovery indexes.
Business data-owner epoch zero is valid (V2RoomDataOwner and rooms schema); it is
not a source/routing lease epoch. Snapshot and transport validation now preserve
that distinction, without inventing epoch one.

Journal baseline RPC carries only minimumCut, never remote authorization grants.
GatewayJournalAuthorityIngress owns four bounded, shutdown-joined cold consumers.
GatewayJournalAuthorityAssembly validates locally acknowledged complete partition
coverage, source-local DB lease, and same-MVCC snapshot before installing authority.
Receiver permits capture source/fence and dynamically check current partition
coverage through actual enqueue. Coverage is withdrawn on pending mutation,
rotation, loss and shutdown; its maintenance is local and performs no routing SQL.
These new assembly helpers compile but are not yet invoked by production Runtime.

Verification: /tmp/imv2-journal-runtime-ports-20261003.log, terminal exit 0,
build 79.81 seconds. 41 server tests in 10 suites passed (including real-PG
repeatable migration/readiness rejection, subscriber installation barrier,
projected H coalescing past the legacy permission window, body audience,
per-frame revocation, Account delivery, trusted baseline, dynamic coverage
withdrawal and fanout retries). Two transport receipt tests passed separately.
Four touched install/bootstrap scripts passed bash -n; git diff --check passed.
No services or capacity loads were started.

Still required before replacement can open listeners: instantiate catalog,
source publishers and authority ingress in Runtime with real routing installation
and shutdown/error ownership; implement non-room permission/control processing;
subscription/user-interest change proof invalidation; per-recipient durable
consumption/last-H anti-entropy; remove old periodic recovery only once replaced;
then execute the original frozen capacity ladder and final device cursor proof.


### 2026-10-03 — revised online/control split

The revised target separates durable business messages, best-effort online body/head acceleration, reliable permission/device controls, and cursor gap recovery. Ordinary H must not use per-Gateway durable consumer responsibility writes. Source latest-H state survives dirty CAS, and shared room anti-entropy repairs a lost last hint.

Implemented this pass: bounded per-Gateway latest-H online dispatcher with independent failed/slow peer retries; incrementally maintained room/user interest indexes and shared multi-device membership; statement-level message/event dirty capture coalescing once per room; RR source head snapshot and source-lease snapshot witnesses. Trusted receiver refuses user control ACK or room-only snapshot recovery before actual user/device floor installation. Cold ingress retains merged user/device hints instead of overwriting them.

Evidence: /tmp/imv2-new-online-design-focused-20261003-r2.log: 17 tests, 5 suites PASS. /tmp/imv2-new-online-design-source-20261003.log: 19 tests, 7 suites PASS, with disposable PostgreSQL enabled, including 20-row statement dirty revision=1 and authoritative H after dirty ACK. /tmp/imv2-new-online-design-final-boundaries-20261003.log: 11 tests, 3 suites PASS after the receiver stale-cut guard change.

Incomplete: production Runtime assembly, initial cold baseline/renewal and shared anti-entropy worker composition, removing the legacy periodic head path after actual replacement coverage, full TCP/fault path verification, and the unchanged capacity ladder. Cold-user paging and authority assembly compile verified by /tmp/imv2-new-online-assembly-build-20261003-r2.log (IMV2ServerApp target, exit 0). These component results are not capacity evidence. Goal remains active.


## 2026-10-04：认证上下文与在线投影分离

已认证 TCP 的正常心跳和消息入口不再以 PostgreSQL 在线租约续期成功作为授权条件。
`V2ConnectionLeaseController` 只维护在线投影、连接准入登记和 SQL 的实际生命周期；
在线记录过期或续期失败不会关闭 socket。会话期限仍由 Session 检查，传输空闲期限
仍由 NIO 控制，设备撤销仍在异步清理之前同步失效写许可。过期在线投影重新登记时
复用原连接身份、发布偏好和准入上限，不能通过恢复绕过准入事务。

首次凭证认证在同一个 SQL 快照取得设备的 `credentialControlVersion`。
用户控制基线只读取用户/设备控制版本，不再联查 `auth_devices` 和
`device_refresh_sessions`。设备版本超过连接认证时的版本就撤销该连接；因此，
认证与控制订阅之间发生的撤销不会漏掉，携带新版本的后继连接也不会被旧事件误关。
会话期限来自首次认证结果，不由控制基线重新计算。

房间订阅续期不再查询数据库激活/房间水位证明，也不再使用 SQL proof broker。
Actor Host 在实际分发轮次时提供当前激活安全期限，并与服务资格期限取较早值。
Subscription Host 通过每宿主一条有界 durable change feed 跟踪权限变化，移除
每五秒遍历所有活动房间的激活/水位查询。订阅续期只读取本地已消费控制版本与序号，
并拒绝尚未处理的 dirty cut。首次 grant 最长 15 秒；续期不得超过最近完整控制流
检查的起始时间加 15 秒，或 Actor 激活安全期限。失败、部分分页或慢查询不能刷新
权限新鲜度。业务日志补拉、实际权限变更恢复和 Actor 所有权续租仍可以访问数据库。

故障语义：数据库在线投影失效时，用户可能暂时显示离线，而已认证连接继续存活。
本地连接上限继续覆盖实际 socket；跨 Gateway 的现有数据库准入上限覆盖有效登记。
在一个 Gateway 的登记过期、另一个 Gateway 接受新连接的故障窗口内，有效登记数
不等于仍存活的 socket 数；这不是严格的全局物理连接数保证。若产品要求在分区中
也维持严格全局 socket 上限，需要独立的用户连接所有者/额度协议，不能再借在线
展示租约隐式撤销认证来实现。数据库恢复后，投影恢复仍必须通过原准入上限。

验证覆盖：认证后多次 TCP 心跳只调用一次认证器；在线投影过期及恢复被拒绝不会
撤销 TCP；过期投影可在原策略下恢复；撤销阻止实际 NIO 写入；房间连续续期不增加
source/read 次数；控制流失败或未完成分页不能延长旧授权；首次控制基线的撤销竞态
与新连接版本受到保护。真实 PostgreSQL 控制基线测试在两个凭证表名不可访问时
已成功，首次认证返回的设备版本也已验证与持久化控制版本一致。

本轮实际验证：`/tmp/imv2-auth-final-tests.log` 覆盖 159 个 Server 测试、
6 个 ServerApp 测试及 28 个 ActorRuntime 测试。唯一失败来自消费者测试
错误假设注册后的水位收件箱为空；注册会预填已有房间水位。修正为失败交付前后
完整状态相等后，`/tmp/imv2-consumer-fix.log` 中 4 个真实 PostgreSQL
消费者测试全部通过。Core 连接状态机另有 2 个测试通过。

范围说明：资源上传和资料展示仍在独立 Account HTTP 请求中校验设备状态；
已核对 Account 路由装配，这些查询不是已认证 Gateway TCP 正常消息链路的
重复认证。本轮没有改动独立 HTTP 请求的身份验证语义，也未进行容量压测。

## 2026-10-04：认证边界修复后的阶梯压测 r1

执行最新 Release candidate，6 Gateway/12 Loader，固定 10k paired fixture，
原 30 秒 rate-1000 场景，消息发送 TCP、结果恢复 TCP query。输出：
`/tmp/imv2-auth-ladder-10k1000-20261004-r1/candidate/`。
首个启动尝试因旧 Loader 算法 hash 不匹配在预检阶段拒绝；重新编译
当前 Loader 后才启动数据库和服务。服务端 Release 编译 226.88 秒，
Account 12.89 秒，Loader 17.50 秒。

第一档 FAIL，未进入 50k/1000 和 50k/5000：10000 authenticated/peak，
29988 sent=ACK，实际 ACK 998.081/s，共同窗口 30.004 秒；连接/业务失败、
心跳漏报、客户端队列溢出/遗弃均 0，客户端发送 drain 与 coverage proof 通过。
最终前景游标核对 missing=0、behind=1084、ahead=0。
这不是整体接收完成或容量通过。

`failure-analysis.json` 对全部最终 cursor 与持久化 room head 逐项比较：
1084 个落后客户端的 announced H 都低于 committed H，1077 个差 1 条，
7 个差 2 条，均没有 pullInFlight/pullSlotReserved/retryPending/gracePending。
故已定位到最后水位通知/兜底恢复未触发，不能将其归因于仍在执行的补拉。
具体通知丢失或状态机原因仍未证实。

整个运行期采样的合计队列峰值（含预热，不代表测量窗口峰值）：
foreground_write=1、interactive_read=90、recovery queued=6120；结束采样均 0。
主机采样 CPU idle 最低 11.62%，结束 56.18%，内存压力 level=1；
结束 swap used=903.56MB。现有证据不能支持 CPU/内存耗尽是失败根因。

清理报告 settled=true、forcedKillCount=0，但 6 Gateway exit=-10 (SIGBUS)，
因此不能宣称服务正常退出。macOS crash report 的捕获时间约 05:54:22，
在测量和客户端最终快照之后；其中栈包含重复 JournalCoverageChange
回调 thunk 和 SharedProjection.remove。`shutdown-crash-analysis.json`
保存 PID、异常和符号摘要；具体根因仍需单独定位。测试子进程已退出，
本次独占 PostgreSQL 按 runner 配置停止并清理测试库，日志保留。

## 2026-10-04：提交事实消费责任保留（进行中）

确认原发送存储在事务提交后、返回成功前同步调用提交观察器，消息序号已经存在，
无需正常路径重新查水位。发现 Feed.take 原先立即清除不可变事实；Host 遇 busy
会把该批正文转为 dirty head，迫使后续 SQL 补读。本轮改为读取不删除，Host
仅用 Owner 实际 consumedThrough 确认前缀；并发更高提交和后继激活受到保护。
删除 Host 的 busy/transient 再投递降级路径，保留原不可变事实直接重试。
正文/字节上限继续包含尚未确认的工作，溢出仍合并 durable repair head。

`/tmp/imv2-commit-responsibility-tests-final.log`：18 个 Feed/Owner/Host 测试通过。
Loader 增加最后一次接受的心跳水位及墙钟时间，仅诊断，不改变发送速率、周期、
恢复或验收。原第一档复跑尚待最新 Release 构建完成，不能声称已解决最终游标落后。
前轮 SIGBUS 仍未修复；最终结果必须同时说明接收收敛和进程退出状态。

提交责任保留复跑结果：`/tmp/imv2-commit-responsibility-10k1000-20261004-r1/candidate/result.json`
仍 FAIL，29988 sent=ACK、实际 999.267/s，但前景游标 behind=1057。
不能从前后吞吐差宣称性能提升，也不能称最终通知缺陷已修复。
`progress-failure-analysis.json`：779 个落后客户端最后有效心跳在发送窗口结束前，
278 个没有接受的进度见证，全部 announced H 落后；没有证据证明其在最后提交后
执行过进度交换。另行创建 60 秒观察场景，保持 30 秒发送窗口和原心跳周期：
`/tmp/imv2-commit-convergence-10k1000-20261004-r1` 在 workload 中 Gateway 提前退出，
0 个最终报告，不构成收敛证明。最新 macOS SIGBUS 栈明确经过
`UserInterests.deactivate -> withdrawJournalCoverage -> receiver.retire -> projection.remove`。
因此不能把崩溃仅限定为正常退出后的清理异常，也不能把 60 秒诊断当作原档通过。
目标仍未完成，需要先定位订阅撤销崩溃，再取得完整水位传播证据。

### 2026-10-04：提交水位收敛与续期竞争（目标仍未完成）

- 已确认提交事务返回前执行 committed observer，提交结果本身已经携带 roomSequence。正常在线水位推进应转交这个事实，不能依靠再次查询数据库重新发现提交。
- Callback Mutex 的栈溢出已有独立最小复现：20,000 次直接读取闭包产生 1,280,000 字节栈漂移，不可变引用包装后为 0；对应 Swift 官方 issue #91348。7 个回调存储改为共享 V2CallbackBox。85 个相关服务端测试通过；Release 原档 10k/1000 复跑 6 个 Gateway 正常退出，forcedKillCount 和 exitFailureCount 均为 0，但 1,034 个接收游标落后。因此栈溢出修复不等于水位问题已修复。
- 同二进制延长 postDrainHoldSeconds 至 60 的诊断 `/tmp/imv2-callback-box-convergence-10k1000-20261004-r1/candidate/result.json`：29,988 条发送与 ACK，仍有 13 个前台游标落后。不能用这份较弱的时间窗口替代原档 10 秒质量门槛。`remaining-lag-analysis.json` 对齐每个落后游标与数据库最终水位、最后接受的心跳水位。13 个连接均持续收到 TCP 心跳响应，但没有在发送阶段结束后接受房间进度水位；没有待执行补拉。现有证据尚不能区分 Gateway 本地 authority 缺失和 socket Ready permit 不匹配。
- 定位并修正一个确定的续期竞争：Relay.canRenew 原先要求请求捕获的 appliedControlSequence 不小于实时 acknowledged。投递 Pump 在续期 RPC 等待期间确认新 body/head，会使正常续期被错误拒绝，进而触发订阅恢复。新的 latestAuthoritySequence 只记录 baseline/grant/revoke/authorizationInvalidated 的序号，替代 acknowledged 比较和 pending 扫描；body/head ACK 前进不会拒绝旧的、仍覆盖全部权限控制的检查点。新权限控制即使已出 pending，旧检查点仍不能续期。
- 新回归 renewalCheckpointSurvivesConcurrentBodyAcknowledgement 在修正前失败，修正后通过；Relay、Owner、Gateway Authority、Registry 和 Integration 共 59 个测试通过。Release 和原档压测验证仍需完成，尚未证明这次修正解决最终投递问题，目标保持 active。

### 2026-10-04：提交 H 与在线消费游标分离（验证中）

- 续期 ACK 竞争修正后的原档 `/tmp/imv2-renewal-race-10k1000-20261004-r1`：29,988 条全部 ACK、991 个接收游标落后，仍不通过，不升级下一阶梯。这个变化不足以证明接收改善。
- 进一步确认 Host.renewalProof 把 `dirty.highWatermark > Owner.consumedSequence` 当成 catchUpRequired，即使权限控制版本完全相同。回归 `committedHeadLagDoesNotInvalidateAnUnchangedPermissionCut` 的版本 0 分支在修改前稳定失败，版本变化分支仍拒绝。
- 修正：权限连续性只比较 roomControlVersion；续期返回 max(Owner 消费游标、精确激活脏水位、本地提交事实 mailbox 水位)。Owner 允许可信提交 H 高于消费游标，保留 Int64 范围检查，不推进消费游标、不释放 mailbox。Feed 的高水位读取只访问该房间至多 64 条消息，不引入 SQL 或全房间扫描。Owner 测试确认前推 H=1 后消费游标仍为 0；权限版本变化仍拒绝；Feed 读取不会转移事实责任。
- 新增低基数 progress 计数：无兴趣、无房间、authority 未 Ready/过期、成员缺失、socket Ready 不匹配与正常 Ready。下一轮可按发送窗口前后差分，区别授权断续和 socket 状态问题，无房间/用户/连接标签。
- 70 个相关测试通过（7 个 suite），Release 与原档验证进行中。目标仍未完成。

### 2026-10-04：续期调度容量缺口（定位并回归验证中）

- 提交 H 分离后的原档 `/tmp/imv2-head-authority-10k1000-20261004-r1` 仍有 1,064 个接收游标落后；6 个服务正常退出。不能声明此前修正已解决最终投递。
- 新计数按正式 30 秒发送窗口差分：progressReady=2,815，progressAuthorityNotReady=3,347，progressAuthorityExpired=4,462；10 秒 hold 的对应增量为 481 / 636 / 863。故回复缺失主要发生在本地房间授权未就绪或过期，不是仅 13 个 socket Ready 标记错位；room/member 缺失没有增加。
- Coordinator.renewLeases 对每个远端 host 只计划一批；某 host 累积到 64 个房间后直接 break，未使用其余 RPC 名额。一秒维护间隔下，同一 host 的选择吞吐被无意限制为 64 room/s。大量房间同截止时间会漏过续期窗口，转成最多 available 个逐房间 rebuild；这一恢复路径比正常批量续期更慢，导致授权反复断续。
- 新回归 samePeerRenewalsUseEveryAvailableCallSlot：129 个房间同 host、相同截止时间、3 个调用名额，一轮应发 [64,64,1]，推进时钟后所有授权仍连续。修正前验证进行中。目标仍 active，原档质量门槛未通过。

- 容量回归的 Debug 修改前结果：一批 [64]，65 个未续期房间随后过期，共 66 个断言失败。修正使用按 peer 索引的开放批次和有界计划批次数，一个 peer 满批后可以在剩余 RPC 名额内开下一批；每批仍至多 64，重建与续期共享原调用预算，原截止时间索引不变。
- 修正后 71 个相关测试（7 suite）通过；同 host 129 个房间实际拆为 [64,64,1]，推进时钟后全部授权连续。Release 原档压测待验证。
- 本次 Release 测试构建曾在 IMV2ServerTests 整模块 SIL CopyPropagation / OSSA 生命周期分析中持续耗时，采样 `/tmp/imv2-release-test-compile-sample.txt` 峰值约 4.9 GB，100% 单核；主动结束这份不必要的优化测试构建，Debug 回归已完成。未把编译耗时当作服务端运行时阻塞，也未放宽压测窗口。

### 2026-10-04：维护与冷订阅的公平准入（验证中）

- 多批续期修正后的 `/tmp/imv2-renewal-capacity-10k1000-20261004-r1` 在预热中止：Loader 8/9 的房间订阅返回 UNAVAILABLE，5 次 50/100/200/400/800 ms 重试耗尽。尚未进入正式发送，不能评估最终水位修复；不能放宽客户端重试预算或收敛窗口。
- 代码确认：初始 relation acquisition 检查 calls < maximumConcurrentCalls，否则直接 overloaded。维护 RPC 的预算为 5 秒，长于上述总重试等待；维护用满名额可使合法冷订阅直接失败。原接口已有 FIFO takeCallSlot/releaseCallSlot，用于退休清理。
- 新回归 coldSubscriptionWaitsForMaintenanceCallSlot 用一个真实持有的续期 RPC 占满唯一名额，验证合法初始订阅等待及关闭期间的实际排空。修正前两种情况均 overloaded，4 个断言失败。
- 修正复用同一 FIFO：初始关系准入受 maximumRelations / maximumReferences 约束，其唯一 acquisition Task 等待实际名额；等待者获得释放名额后重新检查关系引用和 closed，过期引用不创建远端订阅。准备过程保持原 RPC 超时、证明校验和释放逻辑，维护只使用真实空闲名额。不增加独立调度器、不修改客户端或压测预算。新增 acquisitionQueued/admitted 计数。
- 修正后 72 个相关测试（7 suite）通过，包括正常释放后成功、关闭时不创建远端订阅、持有续期关闭排空、多批 129 房间授权连续及权限版本拒绝。Release 原档复跑待完成，目标 active。
- 排除一个此前待核对的观察遗漏假设：sendBatch 的 late-admission recovery 虽返回 nil outcomes，但 processSubmission 携带 acceptanceRejection 时会回滚任何新的 accepted body（682–687 行）。该分支不会提交新的 message acceptance，因此不是漏掉提交 observer 的证据，未修改此路径。

### 2026-10-04：续期失败分类观测

FIFO 修正后的原规格复跑 `/tmp/imv2-cold-fairness-10k1000-20261004-r1/candidate` 仍未通过：29988 条发送全部确认，996 个接收游标落后；阶段内 progressReady=2752、progressAuthorityNotReady=3412、progressAuthorityExpired=4461。运行实际 maximumConcurrentCalls=32。此结果否定了此前修正足以解决收敛问题的判断。

核对 subscriptionRenewBatch 的 Endpoint 实现：每项仍经 host.invoke 的普通 Room lane 执行。Gateway 的 onCleanupFailure 在实际装配中没有传入，因此续期失败原因没有运行证据。新增固定类别续期接受／失败计数，区分远端 unavailable/overloaded/stale/unauthorized/invalidRequest、本地 invalidGrant、调用超时／过载／不可用／位置失效／outcomeUnknown；不含房间、用户或连接标签，不改变续期行为。下一次复跑须以这些分类确定主要失败分支，不能仅凭授权过期计数推断根因。

续期分类 Release 构建成功（186.97 秒），首档 `/tmp/imv2-renewal-observation-10k1000-20261004-r1` 在预热阶段 loader-7 收到 UNAVAILABLE 并终止，未产生发送质量结果。最后完整六节点指标：renewalAccepted=5945、renewalCallOverloaded=2158、renewalOtherFailure=1686、renewalInvalidGrant=1，远端订阅拒绝类别均为零。Endpoint.execute 把 subscriptionRenewBatch 与 recoveryBatch 共用硬编码 activeRecoveryBatches<4、同 serviceID<2 的拒绝式准入；Gateway 同时允许最多 32 个调用。这是已确认的容量／调度不匹配，尚未证明是所有落后问题的充分根因。下一步应修正续期与恢复的资源隔离及生产者容量约束，不能简单放大无界并发。

### 2026-10-04: Separate renewal admission

Host renewal admission is now separate from recovery (recovery remains global 4 / peer 2). Renewal permits peer 2, with total bounded by configured trusted peers times 2 and maximumInboundRequests. Gateway caps actual renewal flights at 2 per physical Host, retains excess due rooms, and retries them after 100ms. The 129-room test renews 64+64 then 1 without grant expiry.

The Cluster Client also shared recovery dispatch capacity with renewals. The in-progress Release build was stopped before changing this path. Client renewal now uses its own per-Host quota of 2, while the outer actual-dispatch limit remains. Timeout/cancellation does not release a permit before the actual operation returns.

Validation: /tmp/imv2-renewal-admission-transport-tests.log contains 36 Gateway tests and 16 Cluster Bridge/Subscription Network tests, all passed. Added recovery saturation / six authenticated peers / per-peer cap / permit release coverage. Release rebuild and unchanged first-stage benchmark remain outstanding; final convergence is not proven.

### 2026-10-04: Isolation runtime result and renewal wire packing

Release build succeeded in 188.46s. /tmp/imv2-renewal-isolation-10k1000-20261004-r1 failed during warmup (UNAVAILABLE); no send quality result. Last complete six-node sample: renewalAccepted=7032, renewalCallOverloaded=0, renewalOtherFailure=2751. The earlier overload category disappeared, but continuity/convergence is still unproven. Added fixed invalidRequest/cancelled/forbidden classifications to avoid grouping known call failures as other.

A focused authentication test demonstrates that 64 distinct valid renewal items with a legal 512-byte callback reference exceed the 65536-byte signed body cap. This proves a count/byte contract mismatch; it does not prove that all observed other failures were oversized. Cluster Client now preflights and partitions renewals by actual JSON byte cost and count, including a conservative maximum sequence/budget envelope. It encodes each item once (linear packing), preserves ordering, sequentially dispatches sub-batches under the original total deadline, and rejects an oversized individual item before any dispatch. Tests verify complete ordered item preservation, successful signing of each partition within the cap, and preflight rejection for an impossible budget. Runtime verification remains outstanding.

### 2026-10-04: First ladder gate passed; 50k warmup capacity mismatch

Release byte-packing build succeeded (180.78s). /tmp/imv2-renewal-packing-10k1000-20261004-r1 passed the unchanged first gate: 10000 authenticated/peak-active, 29988 sent and acknowledged, qualityPassed=true, foreground missing/behind/ahead=0, zero ordinary failures, clean exits. Phase authorityNotReady=2, authorityExpired=5; hold both zero. Final renewalAccepted=64268, callOverloaded=0, callInvalidRequest=0, otherFailure=0. This is runtime proof of first-stage convergence, not proof of the complete ladder.

Advanced to /tmp/imv2-renewal-packing-50k1000-20261004-r1 with the same 1000/s scenario. Failed during warmup, before send barrier. Last complete sample: renewalAccepted=10342, all renewal failure categories zero, progressAuthorityExpired=184018, acquisitionQueued=10119, acquisitionAdmitted=55584. A further deterministic mismatch exists: 50000 connections on six Gateways gives 8333/8334 foreground relations per Gateway, while Runtime hardcodes maximumRelations, authority maximumRooms, and Head Worker maximumRooms to 8192. Runtime now derives all three limits from configuration.maximumConnections, matching physical admission. Cold-acquisition/maintenance shared-slot starvation remains a separate hypothesis requiring evidence. No 50k delivery gate has passed and 5000/s was not started.

### 2026-10-04: Cold-acquisition starvation reproduced

Capacity-aligned Release built successfully (187.94s). /tmp/imv2-subscription-capacity-50k1000-20261004-r1 again failed before the send barrier. Runtime samples showed renewalAccepted stalled at 14913 while acquisitionAdmitted grew from 20748 to 53769 and progressAuthorityExpired from 17380 to 182527, with every renewal failure category zero.

The focused coldQueueDoesNotStarveRenewal test holds four real cold-subscribe port calls against maximumConcurrentCalls=4 while an existing room is due for renewal. Before fix it failed three assertions: four cold calls consumed all slots, no renewal was issued, and the original authority expired. Evidence: /tmp/imv2-renewal-starvation-before.log.

Coordinator now limits foreground acquisition/retirement to half of the existing total call budget (at least one for single-slot configurations), reserving remaining capacity for maintenance. Releasing a slot hands it to FIFO foreground work only when below that limit. Total call bound and peer renewal cap remain. The maintenance interval is 100ms, matching the indexed due-room retry spacing instead of imposing another one-second gap between bounded batches. No new task scheduler or unbounded queue was added.

After-fix Registry/Authority verification passed 37 tests, including starvation regression, cold close, and held renewal shutdown: /tmp/imv2-renewal-starvation-after.log. Release rebuild and 50k unchanged workload verification remain outstanding; first-stage passing evidence remains valid for its tested source snapshot, but full ladder completion is unproven.

### 2026-10-04: Fairness runtime proof and owner-side capacity propagation

Fairness Release built successfully (185.88s). /tmp/imv2-renewal-fairness-50k1000-20261004-r1 still failed during warmup (UNAVAILABLE), before message barrier. Unlike prior run, final renewalAccepted=626943 and progressAuthorityExpired=0; renewalCallOverloaded/invalidRequest/other=0, renewalRemoteOverloaded=2. This proves continued maintenance and removes expiry starvation as the same explanation for this remaining warmup failure.

Credential fixture inspection (counts only, no secrets logged): allTargetRooms=50000, firstTargetRooms=25000, distinct all-target rooms per Gateway=16668/16668/16666/16666/16666/16666. Foreground references remain bounded by local physical connections, but physical Room activation includes additional query targets. Owner resources still defaulted Host/FactsFeed to 8192 rooms and DeliveryPump to 8192 room-by-Gateway bindings. Runtime maximumActiveRooms is 10000; these subsidiary limits were lower than activation admission.

Owner resources now receive maximumActiveRooms from actorConfiguration.runtime and maximumRoomSubscriptionBindings=maximumActiveRooms*configured realtimePeers.count. These flow to SubscriptionHost room bound, committed FactsFeed room bound, and Pump binding bound. Existing default bounds remain for standalone constructors/tests, while production composition supplies deployment-consistent limits. Runtime verification remains outstanding; do not claim all warmup failures are explained solely from this capacity audit.

### 2026-10-04: Owner-capacity warmup reached 11/12 parts; two sockets failed

Owner-capacity Release built successfully (189.67s). /tmp/imv2-owner-capacity-50k1000-20261004-r1 reached 11 ready parts; part-8 logged two post-auth UNAVAILABLE protocol failures (requestID=13), closing those sockets. This run has no reconnects and both warmup counts and start barrier require every requested connection, so its remaining warmup cannot pass. Runner PID 59424 was explicitly interrupted with SIGINT rather than waiting for the 900s timeout; handle 1548 exited130, service cleanup settled with zero forced kills. Exit failures from intentionally interrupted loaders are not evidence of a service crash. No send phase/quality result exists for this run.

Added fixed cold-acquisition error classifications at the actual coordinator acquisition catch: remote subscription failure, call failure, invalid local grant, expired grant, lifecycle supersession, and unknown. Existing metrics alone described maintenance and could not identify these two initial acquisition failures. Loader now fails early during warmup if active connections differ from requested, matching the already-required start barrier condition; terminal room_event_subscribe rejection logs its kind/retry count/code without IDs or credentials. Acceptance, retry count/delays, load rate, and convergence window are unchanged. Canonical loader source hash refreshed using the runner ALGORITHM_SOURCE_SHA256 placeholder.

Verification: /tmp/imv2-acquisition-observation-tests.log passed 37 Registry/Authority tests. New Release server/loader build and runtime diagnosis remain required. Full objective remains active; 50k gate is not passed.

### 2026-10-04: 50k reached send phase; maintenance pass barrier reproduced

Server Release succeeded (185.99s), loader Release succeeded (17.69s), frozen source hash accepted by runner. /tmp/imv2-acquisition-observation-50k1000-20261004-r1 completed all 50000 warm connections and entered the unchanged rate-1000 phase. Quality failed: sent29988/acknowledged29986, behind5505 (5491 lag1,14 lag2), missing/ahead0. Scenario produced12 planned reconnects at this scale. Two unresolved sends were in parts10/11 (TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED), drain pending1 each; part4 coverage proof failed. Phase progressAuthorityExpired=41283, authorityNotReady=5979, ready16141; hold expired12778/notReady4486. Final renewalInvalidGrant=2032, other/callOverloaded/invalidRequest=0. Cleanup settled with forcedKillCount2; this is incomplete runtime behavior, not acceptance.

Audit found maintenance start() awaited renewLeases(), which awaited every admitted Task before the next tick. One delayed peer therefore blocked subsequent maintenance passes even when other peer call slots had become free. heldPeerDoesNotStopMaintenance reproduces this with two Hosts: first renewal held, second peer needs another renewal; old implementation failed the healthyRenewals>=2 assertion (/tmp/imv2-maintenance-barrier-before.log).

Extracted bounded synchronous admitRenewals(). Background maintenance now admits due work without awaiting the whole pass. Flights remain registered in renewalFlights and shutdown still joins them; total and per-peer caps are unchanged. Explicit renewLeases() continues to await the flights it admitted for deterministic callers. After-fix Registry/Authority tests passed38, including held-peer progression and shutdown (/tmp/imv2-maintenance-barrier-after.log). Release rebuild and first/50k gate verification remain outstanding. The two unresolved send operations and coverage-proof failure require separate runtime investigation; no 5000/s run has started.

### 2026-10-04 Owner failure observation and unchanged 50k/1000 gate

The maintenance-independent candidate failed during room warmup, before the send phase, in `/tmp/imv2-maintenance-independent-50k1000-20261004-r1`. Load part 4 exhausted the unchanged five room-event-subscribe retries with UNAVAILABLE. Complete six-node counters recorded 1,123 acquisition remote-overloaded failures, 791 acquisition call-stale failures, and zero authority-expired events. This is not a quality-gate pass.

Distinct Owner busy, catchUpRequired, and overloaded failures share the wire overloaded mapping. Added fixed, identity-free counters before that mapping, plus pumpBindRefused; runtime classification remains pending. Debug verification passed 35 tests across the Owner, Host, and Gateway Registry suites in `/tmp/imv2-owner-failure-observation-tests.log`. Release compilation is in progress; no new runtime conclusion is supported yet.

Audit of the preceding full send run found committed room-head sum 29,986, matching accepted ACK count 29,986 rather than attempted sends 29,988. The two unknown outcomes are not demonstrated committed. Final six-node owner work gauges were zero; PostgreSQL samples showed zero database deadlocks. These observations do not exclude an earlier asynchronous stall.

### 2026-10-04 Peer retry must not reject new room bindings

Observation run `/tmp/imv2-owner-failure-observation-50k1000-20261004-r1` completed the original send phase: all 29,988 sends acknowledged, but 5,554 foreground viewers behind committed H and coverage proof failed. Cleanup settled with zero forced kills. Final fixed reasons: busy 9, pumpBindRefused 1,421, catchUpRequired 0, overloaded 0. Renewal invalidGrant 3,445 and callOutcomeUnknown 256 remain unresolved; this run is not a quality pass.

Pump.bind rejected every new room in a gateway/shard group while that group had a sleeping retry, even though admission already queues and defers dispatch for retrying groups. Removed that group-wide installation rejection; retained capacity, identity, closed-state, and same-key actual-RPC replacement guards. Expanded failedMultiRoomBatchOwnsOneRetryAndCloseJoinsIt to install a 33rd room during the single shared retry and verify no actual call is admitted. Before the fix, the regression failed two expectations; after the fix, 40 Pump/Owner/Host/Registry tests passed. Runtime verification of this change is pending.

### 2026-10-04 Bound renewal admission work including deferred rooms

Pump-only runtime `/tmp/imv2-pump-retry-binding-50k1000-20261004-r1` acknowledged all 29,988 sends but left 5,422 foreground viewers behind; quality and coverage remained false. Cleanup settled without forced kills. No ladder advancement is justified.

The preceding observation run stopped increasing renewalAccepted around four seconds into the send phase, while authority-expired counters continued increasing. Code audit found admitRenewals bounded selected work but not examined/deferred work, and repeatedly used a moving now() to pop due rooms. A busy peer causes reinsertion at now()+100ms; a sufficiently long synchronous turn could revisit deferred rooms. Added an examined-work bound and one admission time cut. This is a code-level progress guarantee, not yet a proven cause of the runtime stall. Existing Registry/Authority verification passed 38 tests; a dedicated adversarial regression and runtime validation remain pending.

Dedicated bounded-admission regression now uses 400 installed rooms, two held same-peer batches, and advances the clock past deferred room deadlines before the next admission. The old loop failed with 545 observed clock/work accesses versus the 130 upper bound; the fixed loop passed. Both temporary old-code runs restored the exact fixed source in finally. Final Registry/Authority suite passed 39 tests in `/tmp/imv2-renewal-bounded-admission-final-tests.log`. This establishes the bounded-work defect and fix; the production stall causal link still requires runtime verification.

Bounded-admission runtime `/tmp/imv2-renewal-bounded-admission-50k1000-20261004-r1` still failed quality: 29,988/29,988 acknowledged, 5,552 foreground viewers behind, phase authorityExpired 36,213 and hold 15,753. Cleanup settled, forced kills zero. The bounded-work regression is valid, but this change did not resolve the runtime failure. A live two-second sample is saved at `/tmp/imv2-renewal-bounded-live-sample.txt`; it did not show admitRenewals monopolizing sampled stacks and contains connection-retirement activity, so it is insufficient to establish a steady-state lock root cause. Next discrimination should separate local renewal rejection reasons, including old grant expiration, from malformed proof. Current scheduling lead is two seconds versus five-second request timeout; this is a timing-risk observation, not yet established causality.

Added fixed local renewal-rejection counters at the actual Coordinator/Authority guards: malformed proof, expired received proof, missing authority, fence/service mismatch, not-ready authority, expired existing authority, control-sequence mismatch, and invalid committed head. No authority validity rule is relaxed. Registry/Authority tests passed 39; Release compilation is in progress. Runtime reason counts remain pending.

### 2026-10-04 Renewal lead must account for request budget

Rejection-observation runtime `/tmp/imv2-renewal-rejection-reasons-50k1000-20261004-r1` failed: 29,984 of 29,988 sends acknowledged, four unknown outcomes, 5,236 foreground viewers behind. Early send-phase local rejection sample was 3,066 invalid grants: 2,963 expired old authorities and 103 not-ready authorities; malformed and expired returned proof counters were zero. This identifies the dominant rejection branch, not all failure causes.

Changed renewal scheduling from a fixed two-second lead to min(requestTimeout + one 100ms maintenance tick, remaining lifetime / 2), bounded below by the existing 100ms scheduling interval. Capping lead at half remaining lifetime avoids repeated immediate renewal for short proofs. Authority expiration, fencing, Ready and control validation remain unchanged. A ten-second grant with a three-second response under a five-second RPC budget now renews before old authority expires and advances H to 11. Old timing failed the same regression; the fixed Registry/Authority suite passed 40 tests. The temporary old-source test restored the exact fixed source in finally. Runtime validation remains pending.

Renewal-budget-lead runtime `/tmp/imv2-renewal-budget-lead-50k1000-20261004-r1` still failed quality/coverage: 29,988/29,988 acknowledged, 5,162 viewers behind. Final counters: renewalAccepted 1,156,650; invalidGrant 1,535, consisting of authorityExpired 1,506 and authorityNotReady 29; callOutcomeUnknown 512; remoteOverloaded 33. Earlier scheduling reduced local expiration rejections but did not restore convergence. Phase authorityExpired 32,402, hold 16,816; zero behind viewers had accepted post-phase progress. Cleanup settled with zero forced kills. Steady-state sample was automatically taken eight seconds after the common barrier, saved `/tmp/imv2-renewal-budget-lead-steady-sample.txt`; unlike the previous sample it contains active submission and delivery stacks. No bounded-admission monopolization is demonstrated. Follow-up must trace unknown renewal outcomes and actual call ownership through timeout/completion, without advancing the ladder.

### 2026-10-04 Observe actual renewal dispatch and unknown-outcome origin

Added fixed renewal failure stages to the existing transport metrics snapshot: caller timeout, caller cancellation, transport error, reply verification failure, invalid batch reply, and remote unknown outcome. An actual-call gauge sums retained per-host renewal dispatch ownership, including callers that already timed out. Existing RPC ownership and error behavior remain unchanged. Counters use independent fixed metric names; no identifiers are emitted.

Cluster bridge/discovery verification passed 19 tests. The metric suite initially failed its old no-label assertion because existing recovery-stage metrics already carry fixed stage labels. Updated that assertion to permit only the known enum stages in the existing two metric families, preserving identity exclusion. The affected two metric tests then passed. Release compilation is running; runtime origin counts remain pending.
