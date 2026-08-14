# Group delivery-mode capacity contract

V2 fixes a group's delivery mode at creation; it never silently switches a
live group between delivery semantics. The mode is part of the persisted room
record and is guarded by a database trigger.

| Member count at creation | Required mode | Ordinary-message path |
| --- | --- | --- |
| `1...5,000` | `standard_fanout` | immutable member audience → outbox → durable per-user sync projection |
| `5,001...100,000` | `large_group_hybrid` | append ordered room event → client room cursor pull; no global user fan-out |

`standard_fanout` is deliberately capped at 5,000 members even though the
generic admission configuration has a `100000` ceiling. `large_group_hybrid`
accepts up to 100,000 members, but its ordinary-message path is a room-log
read model rather than a claim that the system can perform a 100,000-recipient
fan-out for every message.

The historical standard-fan-out benchmarks below remain useful measurements of
the durable projection pipeline, but they do not override this mode policy and
must not be interpreted as permission to create a new 100,000-member standard
group.

## Runtime configuration

The profile is deployed through the required `IM_V2_*` variables in
`IMV2Server/.env.example`:

| Control | Required interpretation |
| --- | --- |
| `IM_V2_MAX_ELIGIBLE_MEMBERS=100000` | reject a command before commit when its immutable fan-out audience is larger |
| `IM_V2_MAX_FANOUT_UNITS_PER_WINDOW` | limits projected user targets, not socket writes or Push sends |
| `IM_V2_MAX_OUTSTANDING_FANOUT_UNITS` / `...PLANS` | caps durable backlog before new room writes are admitted |
| `IM_V2_MAX_ENUMERATION_PAGE_SIZE` | bounds membership enumeration and completion-unit creation |
| `IM_V2_WORKER_BATCH_SIZE` | bounds one planner or delivery worker progression; it is not a throughput promise |
| `IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` | bounds one co-located PostgreSQL delivery transaction to 1...128 targets (baseline 128); a failed batch rolls back its inbox, sequence, sync-log and completion effects together |
| `IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` | bounds one remote target projection plus its later control acknowledgement to 1...256 targets (baseline 256); it is independent from the co-located 128-target transaction and retains target-first retry/idempotency semantics |
| `IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY` | bounds overlapping commits of already-claimed remote batches to 1...2 (baseline 2); it is not extra claim-worker concurrency, and co-located delivery always remains serial |
| `IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE` | bounds lease-fenced deliveries claimed by one delivery worker pass to 1...2,000 (baseline 2,000); it is independent of the generic worker batch and does not enlarge the 128-target atomic transaction |
| `IM_V2_FANOUT_FRESH_BURST_PASSES` | bounds the consecutive fast-path fresh claim passes before one recovery-first pass; delayed retries and expired leases alternate as the recovery-first lane and empty lanes fall through immediately |
| `IM_V2_DURABLE_RETRY_*` | explicitly bounds transient worker retry delay/attempts; exhausted work is paused for alerting and controlled replay, not dropped |
| `IM_V2_MAX_PLANNER_CONCURRENCY` / `...DELIVERY_CONCURRENCY` | bounds independent per-process planner and delivery claim workers; PostgreSQL leases remain the cross-replica fence |
| `IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` | explicit per-event-loop PostgreSQL pool ceiling; it must cover concurrent foreground command/sync work and durable workers, while remaining within the database connection budget across all replicas |

The source transaction reserves room and shard admission capacity. It must not
accept a message and defer quota enforcement to a fan-out worker. Delivery is
per user sync log; live socket hints and Push are expressly outside the cost
of correctness.

The runtime schedules outbox relay/planning independently from delivery. This
prevents a long lease-backed delivery pass from adding its full duration to
new-message plan creation or durable Hybrid-group wake publication. It does
not bypass the PostgreSQL pool: deployment sizing must cover foreground work
plus the configured planner and delivery concurrency.

Delivery also owns a separate runtime task from Push, device revocation,
direct-profile propagation and retention maintenance. Those workers retain
their own durable retry behavior, but a slow provider or maintenance pass can
no longer postpone the next lease-backed delivery claim. This changes cadence
isolation only; inbox, sequence, sync-log, lease and completion semantics are
unchanged.

## Standard-fan-out concurrent baseline

The opt-in `drainsConcurrentGroupMessageWorkload` regression exercises the
actual standard-group ceiling rather than extrapolating from a 100,000-target
drain. It accepts messages through the normal room/admission transaction,
then runs concurrent relay, planning and lease-fenced delivery workers. The
workload shape is bounded to 1...5,000 members and 1...64 messages through
`IMV2_CONCURRENT_ROOM_MEMBER_COUNT` and
`IMV2_CONCURRENT_ROOM_MESSAGE_COUNT`; its delivery claim bound defaults to the
production 2,000 through `IMV2_CONCURRENT_ROOM_DELIVERY_CLAIM_BATCH_SIZE`.
Its planner-page bound defaults to the production 1,000 through
`IMV2_CONCURRENT_ROOM_PLANNER_PAGE_SIZE`, so the regression uses the same
co-located PostgreSQL routing and set-based planning path as the gateway.
`IMV2_CONCURRENT_ROOM_EVENT_PAYLOAD_BYTES` is an optional test-only body
size (0...16,384; default 0); it uses deterministic low-repetition printable
ASCII so PostgreSQL compression cannot hide the cost of duplicating a realistic
message payload into each recipient's durable sync log. It does not alter any
runtime message limit.
The test prints both foreground acceptance percentiles and the per-source
`fanout_plans.terminal_at - room_events.created_at` percentiles. The latter is
the durable end-to-end latency for all recipient projections, not an estimate
from aggregate queue-drain time.

On 2026-07-29, the local four-vCPU / 16-GiB isolated Docker profile produced
the following one-sample regression evidence with synchronous commit enabled:

| Shape | Foreground acceptance P99 | Durable terminal P50 / P95 / P99 | Whole pipeline wall |
| --- | ---: | ---: | ---: |
| 1 message × 5,000 members | 11 ms | 699 / 699 / 699 ms | 732 ms |
| 16 concurrent messages × 5,000 members (80,000 projections) | 75 ms | 5,087 / 7,439 / 7,439 ms | 7,473 ms |

The corresponding 80,000-projection statement sample attributed 6.618s of
database execution time and about 151 MiB of WAL to the set-based projection
CTE (641 calls), and 1.503s / 62 MiB to lease claims (151 calls); database-wide
WAL was about 275 MiB. Short live samples observed `WALWrite` waits but no
relation-lock queue. This identifies durable index/WAL writes as the dominant
cost in this local shape, not the foreground room lock. It is not a production
SLO or a substitute for representative storage and topology measurements.

The regression now starts planning and delivery concurrently, matching the
runtime pipeline instead of serializing them. This changed the measured burst
wall from the earlier 8.601s serial-test sample to 7.473s; it does not change
the durable delivery contract. A separate 1,000-claim experiment completed in
9.100s with 8.156s terminal P99 and increased claim calls to 336, so the
production 2,000-claim bound remains the better local configuration.

A recipient-first fresh-claim experiment was deliberately rejected. It looked
capable of combining several source events into one user-sequence reservation,
but independently planned events can arrive in different batches; preserving a
room's sequence across those batches needs an explicit ordering/watermark
contract, not a claim-order change. It also did not improve the local tail
measurement. Retry-due and expired-lease recovery ordering remains untouched.

### SQL/WAL diagnostic regression

The same disposable-Docker regression now has an opt-in PostgreSQL diagnostic
mode. It resets `pg_stat_statements` **only in that isolated database**, then
prints categorized statement calls, execution time, buffer activity, temporary
I/O and WAL, together with database/WAL counter deltas. It also prints exact
post-run durable-effect counts (inbox/log/payload rows, sequence advances,
delivery claim attempts and terminal/released counts). Those are read from the
verified workload state rather than `pg_stat_user_tables`: per-table statistics
can lag concurrent pooled sessions and are not a reliable exact write count.
It never emits message content, user IDs or raw SQL text. This is intentionally
a measurement aid, not a runtime dependency or a production statistics-reset
permission.

The 2026-07-29 corrected production-path sample (4 vCPU / 16 GiB; 16 messages
× 5,000 members; 1,000-member planner pages) passed with acceptance P99
**69ms**, durable terminal P50/P95/P99 **5.683s / 8.324s / 8.324s**, and a
whole-pipeline wall of **8.355s**. PostgreSQL attributed **7.061s** and about
**150MiB** WAL to the 643 set-based projection CTE calls, **3.199s** and about
**55MiB** WAL to 80 set-based planner-page calls, and **2.296s** and about
**66MiB** WAL to 342 delivery-claim calls. Database-wide WAL was about
**229MiB**; there was no temporary I/O or rollback. The sum of those concurrent
statement times is intentionally greater than wall time.

One 5,000-member-page control sample on the same production path produced an
8.345s pipeline wall and 8.314s terminal P99, statistically indistinguishable
from the 1,000-page sample while increasing projection/claim database time.
It does not justify changing the checked-in 1,000-page production boundary.
The durable projection CTE remains the largest independently measurable cost;
further improvement must reduce its per-recipient indexed writes/WAL without
weakening inbox idempotency, user-sync ordering or the fenced terminal update.

### Payload-copy diagnostic

The production maximum message text size is 4,096 UTF-8 bytes. On 2026-07-29,
the same 16-message × 5,000-member workload with a deterministic 4KiB
low-repetition body per message completed correctly but increased
projection-CTE execution from the then-current short-body local range of
**4.263s...5.626s** to **6.808s** and its WAL from about **130MiB...134MiB**
to **493MiB**. Subsequent metadata compaction lowers the short-body baseline
to about **123MiB**, but does not materially change the large-body conclusion.
The whole-pipeline wall samples overlapped (**8.544s** for the 4KiB sample and
**8.877s** for a later short-body sample), so local wall time is not presented
as a payload-size SLO. The durable WAL multiplier is nevertheless decisive:
80,000 individual sync records each retain a client-readable immutable payload.
The regression asserted that all 80,000 records contained the full 4KiB
`text`, so this measurement could not accidentally become a reference-only
test.

Migration `0029_shared_fanout_sync_payloads.sql` implements the required
target-shard-local shared-payload boundary. New fan-out sync rows are explicit
`payload_storage = fanout_shared` references with a null inline payload; one
immutable `(source_event_id, projection_kind)` JSONB body is kept in
`fanout_sync_payloads` for that physical user shard. Sync pull and authoritative
snapshot reconstruction join it back before encoding the existing client
record, so the wire contract and user sequence remain unchanged. A missing or
mismatched shared row is persistence corruption: it cannot silently become an
empty record, and the whole delivery transaction rolls back.

The local 5,000-recipient / one 4KiB-body regression passed on the same
four-vCPU / 16-GiB Docker profile with **755ms** pipeline wall and **730ms**
terminal latency. Its projection CTE used **6.03MiB** WAL across 42 calls,
instead of the roughly **30MiB** implied by the previous per-recipient body
copy at this shape; total measured delivery WAL-LSN delta was **11.70MiB**.
The result is a local sample, not an SLO, but it confirms that larger bodies no
longer amplify durable writes roughly linearly with recipient count.

The implementation preserves the complete failure boundary: same-store writes
the shared body, inbox fence, sequence, reference row and terminal state in
one transaction; cross-store writes the body and reference row in the target
transaction before fenced control completion; retries validate the immutable
body rather than rebinding a key. User-shard transfer copies a referenced body
before its log row and fingerprints the resolved client-visible payload. Shared
rows are intentionally retained while sync history is retained; a future
history-retention sweeper must remove them only after proving no log reference
remains on that shard.

The same post-fix 16 × 5,000 short-message regression completed in **7.686s**
with **4.248s** projection-CTE execution and **91.72MiB** projection-CTE WAL.
The prior metadata-compacted sample was 7.879s / 4.242s / 123.0MiB, so this
does not claim meaningful short-message CPU improvement, but it removes about
25% of that sample's durable projection WAL without regressing the local wall
sample. The two-statement shared-payload preparation is deliberate: a
single-statement no-op upsert serialized concurrent batches on one source
payload, while a `DO NOTHING` sibling CTE could not see another CTE's insert.

### Co-located claim concurrency ceiling

The remaining short-message latency is not improved by unlimited claim-worker
parallelism. On the same 16 × 5,000 / 80,000-projection local profile, one
co-located user shard completed in **14.052s** with one worker, **9.292s**
with two, **7.686s** with four, **7.570s** with eight, and **7.779s** with
sixteen. Eight is therefore the highest supported claim-pass concurrency for
one physical co-located PostgreSQL bucket. The small eight-versus-four wall
difference is within local variance; the decision is a ceiling, not a promise
that every deployment should create eight concurrent workers.

At sixteen workers, projection execution grew to **4.715s** and claim
execution to **3.437s** across 423 claim statements, compared with the
four-worker sample's **4.248s** projection execution and **1.364s** claim
execution across 196 statements. More concurrency was consuming database
work and lock/claim coordination instead of increasing useful throughput.
`V2CrossStoreFanoutDeliveryStore` now enforces this cap for a co-located
bucket even if process-wide `IM_V2_MAX_DELIVERY_CONCURRENCY` is configured
higher; the checked-in local baseline is eight. Remote shards remain capped at
one concurrent claim pass because they have separate target/control commit
boundaries and already regress under concurrent completion.

`IMV2_CONCURRENT_ROOM_DELIVERY_WORKER_COUNT` is a test-only sweep control
(1...16, default 4); it is not a production environment variable and cannot
override the physical-bucket cap.

The co-located projection CTE also has a guarded distinct-recipient fast path.
Fresh standard-group claims are ordered by source event and target user, so a
normal bounded batch contains one projection per user. In that case each
inbox row reserves exactly one user sequence; the CTE can omit the otherwise
necessary per-user `GROUP BY`, range count and `ROW_NUMBER()` window. It first
checks the actual batch in process. If even one target appears twice (for
example, a caller combines source events for one user), it uses the original
general CTE, which reserves a contiguous range and orders that user's records
by source event. Thus this is a conditional query simplification, not a new
ordering assumption or an API-visible mode.

With the same 16 × 5,000 workload, the guarded path used **4.738s** across
641 projection CTE calls versus **5.614s** across 642 calls when the generic
path was explicitly forced (about **15.6%** less projection-statement
execution time). The corresponding terminal P99 was 7.437s versus 7.985s.
Both runs completed all 80,000 projections without rollback or temporary I/O.
The optimized path also passed the 100,000-target regression with an injected
first 128-target transaction failure: the full batch rolled back and retry
completed all recipients exactly once. WAL and whole-pipeline time remain
storage/concurrency-sensitive, so those single-sample comparisons are not
treated as a production SLO.

### Cross-store projection batches

The runtime already has one delivery worker per logical user bucket and caps
all of them with the process-wide delivery concurrency. Creating another
concurrent **claim** loop inside one remote bucket fragments `SKIP LOCKED`
claims and contends on the same completion units. The safe overlap boundary is
instead inside one already-claimed, ordered lease set. Its useful optimization
is a bounded two-stage batch:

1. For users that are not being moved, the same lease-fenced control-database
   claim statement returns the immutable room-event payload with each claimed
   delivery. It removes the former additional payload-read statement per
   commit batch; a process-local lease that lacks this optional payload (for
   example, an administrative caller) safely falls back to the original
   fenced read. Migration state is still read once per same-bucket batch, so
   ordinary unmoved users do not pay one migration lookup each; any forwarding
   or verified user is split out before this fast path.
2. One target-database transaction writes the remaining same-bucket batch's
   `consumer_inbox`, user sequence reservations and `user_sync_log` rows.
3. After that target transaction commits, one control-database transaction
   lease-fences and terminalizes the corresponding delivery rows, aggregating
   completion-unit counters exactly as the co-located batch path does.

At most two independent remote batches from that same claim may execute stages
two and three at once. Results are consumed in original-batch order before
live-sync hints are emitted. A failure retries only that batch's existing
atomic unit; it neither cancels nor makes visible a parallel batch. The runtime
does not apply this overlap to co-located delivery, forwarding, or verified
migration targets.

This is intentionally **not** a distributed transaction. A crash after stage
one and before stage two leaves a committed inbox effect and a pending control
delivery. On retry the target inbox conflict returns its existing user-sync
sequence; the still-valid control lease can then finish stage two without a
second user-visible record. A failure inside either single-database batch rolls
back that database's entire batch. Users in `forwarding` or `verified`
migration phases retain their established per-target double-write protocol,
because their shadow projection is a separate migration correctness boundary.

The isolated target-store profile on 2026-07-29 projected 1,000 distinct users
in **65ms** as one batch, compared with **986ms** through 1,000 sequential
target transactions (about **15×** for the target half only). It injected a
failure in the first target batch, observed zero inbox and sync-log rows after
rollback, and then retried with identical sequence results. This is neither an
end-to-end latency claim nor a production SLO: the control-store completion,
network topology, WAL device and active migration mix remain material.

The opt-in complete two-database ceiling regression now plans one 5,000-member
standard group in the control database, then drains it through the remote
user-shard path to terminal admission release. On the same local four-vCPU /
16-GiB isolated Docker profile on 2026-07-29, the checked-in remote-256,
commit-concurrency-2 configuration planned in **167ms** and delivered all
5,000 durable effects in **750ms** over three 2,000-target claim passes
(20 × 256-target commit batches). Both target `consumer_inbox` and
`user_sync_log` held exactly 5,000 rows; every control delivery and plan was
terminal.

Its optional two-database `pg_stat_statements` / WAL-LSN profile attributed
about **123ms** of target projection-CTE execution across 20 remote 256-target
batches (about 6.2ms each, 4.33MiB target WAL-LSN delta). In the control
database, payload coalescing removed all former batch payload-read statements.
A serial controlled A/B on the same workload recorded 64 targets at
**1.170s** (80 target batches), 128 at **1.043s / 1.023s** (40 batches), and
256 at **0.943s / 0.957s / 0.963s** (20 batches). The remote-256 improvement is about
8% versus the two 128 samples, while target WAL stayed effectively unchanged.
With that 256-target unit, one same-claim commit window completed in
**743ms / 754ms** at concurrency two (about 21–22% below serial remote-256).
Concurrency three regressed to **871ms**, with higher target execution and WAL,
so the runtime caps and defaults the separate
`IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY` at two. The accepted
overlap raises target WAL from about 4.02MiB to 4.33MiB (about 8%) and is
therefore a measured latency/durability-write trade-off, not free parallelism.
It does **not** justify increasing the co-located 128-target atomic boundary,
where the separate 100k A/B found 256 slower and the smaller recovery unit
remains preferable. All values are local evidence, not a production SLO.

The cross-store claim path also has a payload-size boundary. A payload up to
1KiB remains inline on each claimed lease. For a larger immutable room event,
the same lease-fenced SQL returns its JSON once per source event and the worker
expands that value only in its in-process lease copies before target work
begins. It does not issue a second control-store payload query, and a retry
claims and reconstructs the payload again from the authoritative event. In the
same 5,000-member profile with a 4KiB JSON body, the latest stage-captured
run delivered all effects in **715ms** (planning **143ms**), with **32.7ms**
total control-claim execution and **189.6ms** across the 20 target projection
CTEs.
The stage recorder measured 20 batch calls totaling 30ms of migration reads,
376ms of target projection, 420ms of control completion and 841ms of batch
wall time; those sums intentionally overlap because two batches execute at
once. There were no control/target temporary files and no payload-read
statement. This avoids turning one large message into thousands of repeated
control-query response values; it does not weaken the existing inbox
idempotency, lease fence, rollback, or recovery semantics.

A 512-target remote experiment was rejected even though it halved the batch
count to 10: it delivered in **742ms**, increased target projection execution
to **238.2ms**, and created about **43MiB** of target temporary reads plus
**29MiB** of temporary writes. The deployed remote boundary therefore remains
256: a larger rollback/retry unit must not be accepted merely for reducing the
number of control transactions.

A controlled four-worker experiment against that **same single physical user
bucket** was deliberately rejected: it completed in **1,234ms** (about 19.6%
slower), drove control claim calls from 6 to **80**, and raised the control
WAL-LSN delta from 4.88MiB to **7.08MiB**. `FOR UPDATE SKIP LOCKED` is a
correctness fence, not free parallelism; competing workers fragmented claims
and contended on the same control completion units. The cross-store delivery
store now declares a per-bucket concurrency cap of one to the pipeline. A
follow-up run configured with four global delivery slots still used six control
claims / 40 target batches and completed in **1,077ms**, within local storage
variance of the one-slot result rather than recreating the fragmented-claim
regression. Co-located buckets retain the PostgreSQL store's proven parallel
path. Extra configured delivery concurrency is useful across independent user
buckets, but must not be assumed to improve one hot remote bucket.

Run this diagnostic only against disposable local databases:

```sh
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  -f IMV2/docker-compose.capacity-profile.yml run --rm \
  -e IMV2_RUN_CROSS_STORE_5K_PROFILE=1 \
  -e IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE=1 \
  -e IMV2_CROSS_STORE_5K_DELIVERY_CONCURRENCY=1 \
  -e IMV2_CROSS_STORE_5K_EVENT_PAYLOAD_BYTES=4096 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=profilesCrossStoreFiveThousandMemberDelivery \
  swift-tests
```

`IMV2_CROSS_STORE_5K_EVENT_PAYLOAD_BYTES` is optional (default `0`, maximum
`16384`) and exists only to exercise this local diagnostic. The isolated
PostgreSQL clusters use named disposable Docker volumes so Compose service
recreation does not leak anonymous volumes. The suite removes its `im_v2`
schema after a completed run; use `docker compose -f
IMV2/docker-compose.isolated-tests.yml down -v` to discard all isolated
database and cache volumes.

Run the ceiling regression explicitly when changing fan-out SQL, indexes,
worker concurrency or PostgreSQL settings:

```sh
IMV2_RUN_CONCURRENT_ROOM_WORKLOAD=1 \
IMV2_CONCURRENT_ROOM_MEMBER_COUNT=5000 \
IMV2_CONCURRENT_ROOM_MESSAGE_COUNT=16 \
IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE=1 \
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  -f IMV2/docker-compose.capacity-profile.yml run --rm \
  -e IMV2_RUN_CONCURRENT_ROOM_WORKLOAD=1 \
  -e IMV2_CONCURRENT_ROOM_MEMBER_COUNT=5000 \
  -e IMV2_CONCURRENT_ROOM_MESSAGE_COUNT=16 \
  -e IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE=1 swift-tests
```

## Foreground group preview and `large_group_hybrid` correctness boundary

Both fixed group modes may use the existing authenticated TLS/protobuf
connection while the user is actively viewing one group detail. On a newly
accepted group message, the Gateway emits only a best-effort
`(room_id, high_watermark)` hint after the source transaction commits. The
client then performs an authorization-checked `GroupEventPull`; the hint never
contains content or recipient identity. Every pull rechecks current membership
and each event's committed-membership revision, so a stale subscription or
late hint cannot disclose payload after removal.

For `standard_fanout`, this is a **transient foreground preview only**. The
client starts from a process-local lower-bound cursor based on already
projected room messages, applies the result idempotently, and does not write
the Hybrid group-event cursor or advance a personal-sync ACK. Therefore a
lost hint, app restart, broker outage, or preview failure simply falls back to
the existing inbox/user-sync-log delivery path. This improves online
detail-view latency without weakening the all-recipient reliable delivery
semantics measured above. An idempotent send replay emits no second hint.

For `large_group_hybrid`, the same metadata route is backed by the durable
wake outbox and an on-device durable per-room cursor, because the room log is
the ordinary-message delivery model.

For a hybrid room, an ordinary message is appended atomically to
`room_group_events` with a strictly increasing room event sequence. A client
that is an active member pulls pages after its durable per-room cursor; the
cursor and received events commit in one local transaction, so an interrupted
pull is safely replayed. Member joins, removals and moderation controls carry
the persisted delivery mode, allowing a newly joined client to begin the same
cursor-based path. The app runs this catch-up after its normal durable
sync/reconnect pass. While a user is actively viewing a hybrid conversation,
the detail view first opens a room subscription on the existing authenticated
TLS/protobuf connection. After catch-up, it waits for a request-ID-zero
`GroupEventAvailable` metadata frame and cursor-pulls only that room; an empty
result resumes the wait. A 30-second recovery pull exists solely for a lost
broker/TLS hint, while a short backoff is used only when the connection itself
fails. Leaving the detail view cancels the task and sends unsubscribe. A
standard group uses the same subscription only while that one detail is
visible, and its pull remains a transient preview rather than a durable
delivery acknowledgement. This is neither a member-wide online notification
nor a background poll over every joined room.

On the Server, inserting a hybrid room event atomically coalesces that room's
latest sequence into `group_event_wake_outbox`. A lease-fenced relay publishes
only `(room_id, high_watermark)` metadata after commit; a newer event revision
survives an older in-flight relay completion. The command handler also emits
the immediate, lossy foreground hint for either group mode after its accepted
source transaction; failure is ignored and can never turn an accepted send
into an error. A single Gateway can notify its local connection registry
directly. In a multi-Gateway deployment each replica uses one reusable Core
NATS connection and dynamically subscribes only to rooms being viewed locally.
Subject names derive from HMAC-SHA256(room ID, deployment routing key), so
stable room UUIDs are not used as broker subjects. NATS is an availability
accelerator, never a correctness dependency: duplicates, loss, broker restart,
or a relay retry are repaired by Hybrid cursor pull or standard personal sync.

An explicit user mention is the intentionally finite exception: it creates a
normal durable fan-out plan only for the deduplicated mentioned users (never
for `@everyone`). With no explicit user mention, the hybrid acceptance path
creates no `fanout_plan_targets` and no `room_outbox` work. This preserves
reliable mention delivery without reintroducing all-member work.

Mention authorization is bounded by the command limit: it locks and checks
the sender plus only the explicitly named users, never every active member
merely to authorize one mention. Membership revision, active-membership and
bilateral-block checks remain server-derived in the same source transaction;
`@everyone` still requires owner or admin. This prevents one reliable mention
from turning into a group-size-scaled lock/read in a large Hybrid room.

The opt-in disposable-PostgreSQL regression
`acceptsOneHundredThousandMemberHybridRoomWithoutGlobalFanout` seeds 100,000
active members, accepts one ordinary message, pulls its first room-event page,
then accepts an explicit single-user mention. It asserts zero ordinary fan-out
targets, exactly one mentioned-user target and one outbox row. On 2026-07-29,
the local four-vCPU / 16-GiB Colima profile (Swift test container: 4 vCPU,
12 GiB; isolated PostgreSQL) produced:

| Phase | Wall time |
| --- | ---: |
| schema install | 236 ms |
| seed 100,000 memberships | 692 ms |
| ordinary hybrid acceptance | 13 ms |
| first room-event pull | 6 ms |
| explicit single-user mention acceptance | 18 ms |
| end-to-end test | 966 ms |

The mention time includes the same PostgreSQL room/admission transaction as a
reliable fan-out source; it is not a global fan-out completion time. The
bounded authorization change reduced the previous local one-user mention
sample from 3,130ms to 18ms by removing the all-member lock/read. These are
one local regression sample, not a production latency SLO. The test is run
explicitly because it creates 100,000 rows:

```sh
IMV2_RUN_HYBRID_100K_CAPACITY=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_HYBRID_100K_CAPACITY=1 swift-tests
```

### 100,000-member group bootstrap

Large-group creation is a one-time bootstrap cost. The immutable `room.created`
event makes the room visible to every initial member, so its single transaction
writes the room, 100,000 memberships, the idempotency record, and a 100,000
target bootstrap fan-out plan. This does not change ordinary Hybrid-message
delivery: ordinary messages still append only to the room event log.

The opt-in disposable-PostgreSQL regression
`createsOneHundredThousandMemberHybridRoomAtomically` verifies exactly those
rows and the one operation record. On 2026-07-30, a local isolated PostgreSQL
run completed creation in **1,958 ms** (2,567 ms total including 319 ms schema
installation). This is one-client, one-shard bootstrap evidence—not a
concurrent-create SLO or a message-delivery latency claim.

```sh
IMV2_RUN_HYBRID_100K_GROUP_CREATE=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_HYBRID_100K_GROUP_CREATE=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=createsOneHundredThousandMemberHybridRoomAtomically \
  swift-tests
```

The foreground cadence is an implementation bound, not a measured latency SLO:
the current local regression verifies task ownership, cancellation-compatible
room mode gating, cursor durability, and projection refresh. It does not yet
measure end-to-end device-visible latency under sustained high-frequency group
traffic.

## Executable scale-shape and full-drain regressions

The disposable-PostgreSQL Server suite includes a 100,000-member planning
regression. It creates a single immutable audience, uses a `1000` member page,
and asserts 100 completion units, 100,000 delivery rows, 100,000 distinct
recipients and a terminal `planned` plan state. Run it with the normal isolated
Server suite:

```sh
docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm swift-tests
```

Each planning page atomically persists its completion unit, delivery rows and
enumeration checkpoint; a separate interruption regression proves a restarted
planner resumes after a committed page and that delivery cannot consume a
partially enumerated plan. This checks page bounds and durable accounting only.
It intentionally does not start concurrent senders, drain all deliveries, open
sockets, send Push, or measure latency; it is not capacity evidence.

An opt-in PostgreSQL regression also drains all 100,000 deliveries using four
concurrently scheduled delivery workers and a four-connection pool. Each claim
is independently configurable; the validated baseline is 2,000 targets while
each projection transaction remains bounded to 128 targets. Every worker must
claim work. Transactional
contention follows the normal durable retry path with a short deterministic
test-only 10–100ms backoff, and the gate requires eventual zero `paused`, zero
stale-route/stale leases, one user-sync projection and one consumer-inbox
record per recipient, all 100 completion-unit releases, terminal plan state,
and release of the room and shard admission reservations. Because this creates
200,000 durable projection and inbox rows through the real per-delivery
transaction path, it is excluded from the normal suite:

```sh
IMV2_RUN_100K_DELIVERY_SOAK=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_100K_DELIVERY_SOAK=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=drainsOneHundredThousandMemberAudienceExactly swift-tests
```

On 2026-07-27, the local Docker baseline (two CPU limit, isolated PostgreSQL,
four delivery workers) completed this drain in **113.144 seconds**. This is
end-to-end concurrency and delivery-correctness evidence, not a throughput
benchmark or SLO: it uses one isolated PostgreSQL instance and does not
represent concurrent room writes, multi-replica workers, live sockets, Push,
or production topology.

On 2026-07-28, the dedicated Colima profile was raised to four CPUs and 16 GiB
(the test container is capped at four CPUs and 12 GiB, leaving the remaining
memory for PostgreSQL and NATS). The same drain passed in **115.565 seconds**.
This single rerun is statistically indistinguishable from the two-CPU baseline
and does not show a CPU or memory scaling improvement; the workload is
currently dominated by the single PostgreSQL instance's per-recipient durable
transactions and index writes.

### WAL durability decision

The opt-in 100k regression now prints the effective PostgreSQL
`synchronous_commit` value with its timing, so a parameter comparison cannot
silently compare different session durability policies. On the same isolated
four-worker / 128-target-commit / 2,000-claim workload on 2026-07-29, two
`synchronous_commit=on` runs spent **10.005s** and **9.993s** in delivery. A
test-role-only `off` run spent **9.605s** (about **3.9%** faster than the mean
`on` result). The isolated role setting was reset immediately after the run.

This is not an acceptable production trade: `off` can acknowledge a committed
message before WAL is durable and can lose that acknowledged tail during a
database crash. Production remains `synchronous_commit=on`; further latency
work must reduce write-path cost rather than weakening the durable delivery
contract.

### PostgreSQL profile

`docker-compose.capacity-profile.yml` is a local-only overlay that preloads
`pg_stat_statements`; it does not alter the application schema or a production
database configuration. On 2026-07-28, after resetting PostgreSQL statistics,
the same 100,000-recipient drain passed in **114.138 seconds** with
`synchronous_commit=on` and `wal_level=replica`. Its workload produced
**377,216,464 bytes** (about **359.8 MiB**) of WAL, **100,883** committed
transactions, zero rollbacks, and **385,793,216 bytes** (about **367.9 MiB**)
of temporary-file I/O.

The leading statement was the four-worker `fanout_deliveries` claim CTE:
`WHERE target_shard_bucket/state/ready AND ORDER BY source_event_id,
target_user_id LIMIT ... FOR UPDATE SKIP LOCKED`. Across 401 calls it consumed
**9.900 seconds** of PostgreSQL execution time, **107.24 MiB** of WAL and
47,037 temporary blocks written (about **367.5 MiB**). The current claim
indexes do not match both its ready-time predicates and its ordering, so the
query spills while selecting the next batch. The next section records the
result of replacing that mixed claim with lane-specific queries and indexes.

### Claim lanes and recovery fairness

Migration `0020_fanout_delivery_claim_lanes.sql` adds three partial indexes:
one for brand-new deliveries, one for due delayed retries, and one for expired
leases. The delivery worker selects exactly one mutually exclusive lane in a
transaction: `fresh` requires both timestamps to be null; `retryDue` requires
an unleased due retry; `expiredLease` requires an elapsed lease and, if a retry
timestamp remains, that it is also due. Thus a claim token is still generated
and fenced by the same atomic update, and the commit path still uses the same
consumer-inbox uniqueness key.

The runtime gives `fresh` seven claim turns by default, then schedules one
recovery-first turn. Recovery-first turns alternate delayed retries and expired
leases. A lane that is empty falls through to the next lane immediately, while
a nonempty lane consumes the whole bounded batch; this avoids a partial
multi-lane lease transaction. `IM_V2_FANOUT_FRESH_BURST_PASSES` is required
configuration rather than an implicit constant, so recovery latency remains a
reviewable deployment choice.

On 2026-07-28, the opt-in 100,000-recipient drain passed after this change in
**112.796 seconds** on the same four-CPU/16-GiB Colima profile (the Swift test
container remained capped at four CPUs/12 GiB). This is **1.342 seconds
(1.2%)** below the earlier 114.138-second profiled run, so it is not evidence
of a materially higher end-to-end throughput ceiling. The bulk of the wall
time is still the required per-recipient inbox, user-sync sequence/log and
completion transactions.

The PostgreSQL statement profile does show that the intended hot path changed:
the 401 nonempty fresh-lane claim CTEs used **2.462 seconds** of execution
time, **5,399,487** buffer hits, **104.24 MiB** of WAL and **zero** temporary
blocks written. The pre-change mixed claim used 9.900 seconds, 14,767,538
hits, 107.24 MiB WAL and 47,037 temporary blocks (about 367.5 MiB). The new
run's database-wide temporary I/O was only 1,400,000 bytes, and none was
attributed to the fresh-lane claim. This is strong local evidence that the
matching partial index removed the original claim-sort spill; it does not
replace a representative production-topology load report.

The opt-in soak now prints one privacy-safe `V2_LOCAL_100K_DELIVERY_TIMING`
line with schema, seed, planning, delivery and verification wall time plus the
four workers' aggregate batch/commit distribution. A diagnostic rerun on the
same profile passed in **114.318 seconds**: schema **260ms**, seed **875ms**,
planning **4,706ms**, delivery **108,325ms**, and verification **34ms**. The
four workers committed 24,713 / 25,000 / 25,172 / 25,115 projections across
25 / 25 / 26 / 26 nonempty batches respectively; the remaining scheduled
passes were empty. Its statement profile again recorded zero temporary blocks
for the 401 fresh claims (2.874s database time). This confirms the load is
fairly distributed at the worker layer, while the 108-second delivery phase
remains the dominant cost.

### Bounded atomic delivery batches

For a target whose configured logical bucket is physically the control
database's `im_v2` schema, the worker commits a configurable 1...128 targets
(baseline 128) in one PostgreSQL transaction. One JSONB recordset/CTE input
locks the fenced deliveries, bulk-inserts inbox rows, reserves one contiguous
sequence range per recipient, bulk-appends sync logs, and terminalizes each
delivery under its lease token. Completion accounting remains aggregated once
per `(source_event_id, completion_unit_id)`. A crash or SQL failure rolls back
the entire batch; normal retry reclaims every member and inbox uniqueness
remains the idempotency fence.

This optimization is deliberately unavailable when a target uses another
database/schema, or when a forwarding/verified user migration requires a
shadow write. Those routes retain the target-first, control-complete protocol,
because a local PostgreSQL transaction cannot span physical stores. The timing
figures above predate this batch implementation and are historical baselines.
On 2026-07-28, the same four-CPU/16-GiB isolated profile completed a fresh
set-based 100k drain in **17,097ms**: schema **288ms**, seed **780ms**,
planning **4,689ms**, delivery **11,229ms**, verification **82ms**. Compared
with the preceding 72,326ms per-target-SQL batch implementation, delivery is
**61,097ms (84.5%)** lower; compared with the 108,325ms diagnostic baseline it
is **89.6%** lower. Worker commits were 24,366 / 24,536 / 25,036 / 26,062 across
26 / 25 / 27 / 28 nonempty claims, so the improvement did not come from
silently reducing delivery work. PostgreSQL recorded 1,603 set-projection CTE
calls totalling 6,615ms and 158MiB WAL, instead of 100,000 calls for each
inbox/sequence/log/terminal statement. This remains local single-PostgreSQL
evidence, not a production capacity guarantee.

On the same isolated profile, a three-run batch-size comparison held the
four-worker topology and 100,000-recipient workload constant. Batch 128 was
the local knee point: its mean delivery wall time was **11,195ms**, compared
with **12,340ms** at 64 (-9.3%). It reduced projection transactions from about
1,603 to 802 and WAL syncs from about 2,035 to 1,238. Batch 256 reduced those
counts further but raised each projection CTE to about 22ms and regressed mean
delivery time to **12,441ms**. Therefore 128 is the checked-in baseline, not a
general production SLO. A separate 100k recovery regression injects one first
projection-batch failure: all 128 members roll back, are released for retry,
are claimed at retry count two, and still finish with exactly 100,000 inbox and
sync-log rows, terminal delivery rows, released completion units, and released
room/shard admission.

After the later shared-payload change, this failure boundary was rerun on
2026-07-29 with the checked-in 128-target batch size: it completed in
**11,276ms** total (**8,299ms** delivery), released exactly 128 failed leases,
and committed all 100,000 final projections. The independent 100k
lease-expiry recovery gate also passed after the same change: it interrupts
each of the 100 completion units before its first checkpoint, after one
checkpoint, before the final terminal update, and after that update, then
proves only remaining targets resume and every durable effect is exactly once.
That deliberately sequential correctness gate took **201.928s**; it is not a
throughput measurement and is intentionally kept separate from the concurrent
drain timing above.

### Post-batch write-path profiling

After collecting a fresh `pg_stat_statements` profile on 2026-07-29, the
remaining local delivery wall time was not improved by simply widening leases:
2,000-target claims drained in **9.626s**, while a 4,000-target experiment
drained in **9.586s**. The 0.4% difference does not justify doubling the
lease-recovery blast radius, so the required runtime maximum remains 2,000.

The same profile showed that every terminal completion unit locked the same
`fanout_plans` row even though only the final unit can close a plan. Release
now serializes through the already-required room admission row, then locks the
plan only for the sole final transition. A normal 100k drain passed in
**9.626s**, and the profile no longer attributed a multi-second shared-plan
lock wait to the 100 terminal unit releases. The injected first-projection
failure regression also passed, preserving the existing 128-row rollback and
retry semantics.

The projection CTE now materializes its merged JSON payload once per distinct
`(source event, projection kind)` within a commit batch, then joins that
immutable value to the target rows. This avoids repeating the same JSONB merge
for every target without changing inbox identity, sequence allocation, sync
payload, lease fence, or completion accounting. Fresh normal and injected
failure 100k drains passed in **8.845s** and **8.823s**, respectively. A
separate moderator-redaction integration test confirmed that an event-bearing
payload remains visible to the recipient unchanged.

The key de-duplication is intentionally a separate materialized CTE before
the JSONB expression. `SELECT DISTINCT` over an already-computed payload may
still evaluate that expression once per recipient before it discards equal
rows. In a back-to-back 16-message × 5,000-member (80,000 projection) local
profile on 2026-07-29, making this ordering explicit reduced cumulative
projection-CTE execution from **4.743s** (643 calls) to **4.263s** (644 calls,
about **10.1%**) and whole-pipeline wall from **8.127s** to **7.972s**. CTE WAL
was effectively unchanged (about **130.5MiB**), as expected: the optimization
removes repeated JSONB CPU work, not any durable inbox, sequence, sync-log or
lease write. The injected 100,000-target first-batch-failure regression also
passed after this change (10.119s delivery wall in that local recovery run),
with exactly one final durable projection per recipient.

Fan-out sync rows also no longer repeat `source_event_id` or
`projection_kind` inside their JSONB payload: those are already immutable
columns on `user_sync_log` and explicit fields of every sync-protocol record.
The sync pull and snapshot paths use the columns as their authority, so this
removes redundant bytes without changing the client-visible record or making
the payload a reference. In a later 16 × 5,000 short-message profile, this
reduced projection-CTE WAL from about **130.6MiB** to **123.0MiB** (about
**5.8%**) and had a locally comparable 7.879s pipeline wall. One real
same-store regression verifies the protocol fields, payload contents and
snapshot; a separate cross-store target-outage/retry regression verifies the
same rule through target-first recovery. The shared-payload 5,000-recipient
4KiB-body run also asserts every delivered sync record resolves to the
complete text through its target-shard payload row.

Two experiments were intentionally not adopted. PostgreSQL typed-array input
to the projection CTE raised its database execution time from **6.75s** to
**7.99s** in this driver/profile, so the JSONB recordset remains the faster
input boundary here. Increasing the planner page from 1,000 to 2,000 reduced
planning time somewhat but produced **9.660s** and **9.435s** delivery phases,
both slower than the 1,000-page baseline; production therefore retains the
existing page size. These are local measurements, not a capacity SLO.

### Set-based planning and route snapshots

Migration `0023_fanout_set_based_planner.sql` adds a durable
`enumerated_target_count` to each plan. For the production co-located
PostgreSQL router, one planner page now uses one CTE statement to materialize
the revision-fenced candidate set, join the current logical route/epoch,
create one completion unit, insert its delivery rows, and advance both the
keyset checkpoint and enumerated count. The page commits all of those facts
together or rolls them all back. When its count reaches `target_count`, it
moves the plan to `planned` in that same update, so no final delivery-table
`COUNT(*)` scan is required. A deliberately non-PostgreSQL router keeps the
injected-router path because its routing facts cannot be assumed to exist in
the control database.

The delivery worker now resolves the current route once per bounded claim, in
input order, rather than once per recipient. It still compares the stored
write identity for every lease and performs each stale-route handoff with its
own claim-token fence. A failed route lookup retries the claim; a failed
handoff retries only that durable row.

The 100k planner recovery regression injects a database failure while writing
the second one-target page, proves only the first page/checkpoint is durable,
then removes the fault and completes exactly once from that checkpoint.

On 2026-07-28, after both changes, the same local four-vCPU/16-GiB isolated
profile completed the full 100,000-recipient regression in **16,380ms**:

| Phase | Previous fresh set-based sample | New sample | Difference |
| --- | ---: | ---: | ---: |
| schema | 288ms | 272ms | -16ms |
| seed | 780ms | 734ms | -46ms |
| planning | 4,689ms | 3,294ms | **-1,395ms (-29.8%)** |
| delivery | 11,229ms | 11,969ms | +740ms |
| verification | 82ms | 79ms | -3ms |
| total | 17,097ms | 16,380ms | **-717ms (-4.2%)** |

All 100 completion units released; the four workers committed 25,309 / 25,000
/ 25,272 / 24,419 projections. These are two single local samples, so the
small delivery difference is run-to-run noise rather than a claimed
regression. The planning reduction is the relevant result of this change;
neither table is a production SLO or a capacity extrapolation.

## Historical 1,000-member concurrent baseline

The default 16-message × 1,000-member form of the same opt-in regression is
retained as a fast development smoke workload. It is historical context for
the current 5,000-member ceiling measurement above, not a substitute for it.
Every send uses the real room sequence/admission transaction; four concurrent
relay passes and four delivery workers overlap to project all 16,000 receiver
effects. The test requires exactly 16 accepted messages,
contiguous room sequence through 16, terminal fan-out plans, 16,000
sync-log/inbox/delivery effects, no stale or paused work, and complete
room/shard admission release.

```sh
IMV2_RUN_CONCURRENT_ROOM_WORKLOAD=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_CONCURRENT_ROOM_WORKLOAD=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=drainsConcurrentGroupMessageWorkload swift-tests
```

On 2026-07-27, this completed in **17.084 seconds** in the same local two-CPU
Docker/PostgreSQL baseline. The 16 send-acceptance samples recorded p50
**39ms**, p95 **59ms**, and p99 **59ms** (nearest-rank calculation; p95/p99
are necessarily coarse for 16 samples). The test prints these values as one
machine-readable `V2_LOCAL_CONCURRENT_ROOM_WORKLOAD` line on every opt-in run.
They are a repeatable local regression report, not production thresholds,
throughput/SLO evidence, or an extrapolation to a 100,000-member high-frequency
group.

The 2026-07-28 four-CPU/16-GiB profile rerun passed in **17.633 seconds** with
p50 **50ms**, p95/p99 **77ms**. The 16 samples are too small to treat the
small difference as a regression or a scaling result; it confirms the same
correctness envelope under the enlarged local resource profile.

The opt-in gate also enforces broad local regression ceilings: acceptance p99
must not exceed **250ms** and complete pipeline wall time must not exceed
**60,000ms**. These defaults are intentionally several times wider than the
recorded baseline; override either on a different local machine with
`IMV2_LOCAL_CAPACITY_MAX_ACCEPTANCE_P99_MS` or
`IMV2_LOCAL_CAPACITY_MAX_PIPELINE_WALL_MS`. They protect this reproducible
development workload from an order-of-magnitude regression and are explicitly
not production SLOs, admission limits, or approved capacity thresholds.

On 2026-08-13, the same isolated Linux/arm64 Docker smoke path was rerun after
the system-wide performance pass. It completed all **16,000** receiver
projections with acceptance P50/P95/P99 **74/114/114ms**, durable terminal
P50/P95/P99 **1,419/1,909/1,909ms**, and a **1,925ms** pipeline wall. The
fixture now also inserts the sender's active public-profile fact required by
production message admission; membership alone no longer bypasses that gate.
The sample passes the checked-in regression ceilings, but its different host,
warm Docker volumes and single local PostgreSQL mean it must not be compared
numerically with the 2026-07 samples as a throughput improvement or production
SLO.

An additional opt-in recovery soak covers the failure boundaries that a full
drain cannot. For each of the 100 completion units it loses a worker before
the first target checkpoint, after one durable target checkpoint, immediately
before the final target's terminal/release update, and immediately after that
terminal update. Each lease-expiry replacement must resume only remaining
targets. The test requires exactly 100,000 terminal deliveries, one sync-log
and one inbox projection per recipient, all 100 unit releases, a terminal
plan, released room/shard reservations, and no work claimable after a unit has
released:

```sh
IMV2_RUN_100K_CRASH_RECOVERY_SOAK=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_100K_CRASH_RECOVERY_SOAK=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=recoversOneHundredThousandMemberAudienceAfterEveryCompletionUnitInterruption swift-tests
```

This establishes lease-expiry recovery and exactly-once durable effects across
the target-checkpoint and terminal-release boundaries at the 100k scale. It
remains a single-container correctness soak, not a production throughput or
availability claim.

## Planned co-located fresh-delivery transaction

The 2026-07-29 16 × 5,000 diagnostic committed 80,000 new deliveries through
two `fanout_deliveries` state changes: lease claim and terminalization. Its
exact durable-effect report recorded 80,000 claim attempts and 80,000 terminal
rows; the claim statements alone used about 51MiB WAL. The next material
latency optimization is therefore not a larger worker pool, but an optional
co-located **fresh-only** transaction that selects ready rows with `SKIP
LOCKED`, projects inbox/sequence/sync effects, terminalizes those same rows,
and updates completion accounting before one commit.

It may run only when all of these are true:

1. the target bucket is the control database's `im_v2` schema;
2. the row is fresh (no retry time and no previous lease), and the current
   route still equals its persisted bucket/epoch;
3. no forwarding or verified user migration applies; and
4. the transaction holds a key-share lock on the router configuration before
   reading effective routes, so a cutover's configuration `FOR UPDATE` cannot
   interleave with a projection.

Any unavailable route, route mismatch, migration, SQL failure, retry-due row,
or expired lease must fall back to the existing claim-token path unchanged.
The fast transaction must not manufacture a lease, skip a target, or turn a
failure into a terminal result. Its acceptance gate is a fresh 80k SQL/WAL
comparison plus the existing injected-batch-failure, 100k lease-expiry
recovery, cross-store outage/retry, and user-shard-transfer regressions.

As an immediately safe reduction before that larger transaction exists,
co-located claims now omit the event payload. Their native `commitBatch`
already reads the authoritative event inside its own transaction, so the
former claim-time event join and JSON/process-memory copy had no consumer.
Remote claims retain their payload enrichment because their separate target
transaction needs it. A two-database integration regression asserts this
distinction while preserving target-first retry and migration behavior.

## Release gate for the profile

Before enabling this profile in production, record a dated load report with:

1. topology: PostgreSQL version/instance sizing, number of gateway and worker
   replicas, region, room/user-shard distribution, and configured values;
2. workload: one 100,000-member room, concurrent rooms, message rate and
   payload distribution, online-device fraction, reconnect and duplicate-send
   mix, and sync-pull rate;
3. assertions: no duplicate `(user_id, source_event_id, projection_kind)`
   projections, no gap in each recipient user-sync log, stable source-room
   reservation release, and reconnect convergence after worker/gateway restart;
4. limits: p50/p95/p99 acceptance latency, fan-out completion age, PostgreSQL
   CPU/IO/lock waits, worker lease expiry/retry counts, backlog peak, and
   rejection behavior under overload;
5. failure tests: gateway kill during response loss, worker kill after claim,
   PostgreSQL failover/temporary unavailability, loss of live hints, and
   revocation during sync;
6. pass/fail thresholds approved by the capacity owner. A failed or missing
   report requires a lower admission profile rather than an optimistic limit.

No release may infer a 100,000-member guarantee from unit tests, a small-room
benchmark, or linear extrapolation.
