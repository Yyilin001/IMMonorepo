# `standard` 100,000-member group capacity contract

`standard` is the only currently declared V2 profile. Its `100000` member
limit is an admission boundary, **not** a claim that a deployment can serve a
100,000-member high-frequency room without measurement.

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
| `IM_V2_DURABLE_RETRY_*` | explicitly bounds transient worker retry delay/attempts; exhausted work is paused for alerting and controlled replay, not dropped |
| `IM_V2_MAX_PLANNER_CONCURRENCY` / `...DELIVERY_CONCURRENCY` | bounds independent per-process planner and delivery claim workers; PostgreSQL leases remain the cross-replica fence |

The source transaction reserves room and shard admission capacity. It must not
accept a message and defer quota enforcement to a fan-out worker. Delivery is
per user sync log; live socket hints and Push are expressly outside the cost
of correctness.

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

An opt-in PostgreSQL regression also drains all 100,000 deliveries. It verifies
one user-sync projection and one consumer-inbox record per recipient, all 100
completion-unit releases, terminal plan state, and release of the room and
shard admission reservations. Because this creates 200,000 durable projection
and inbox rows through the real per-delivery transaction path, it is excluded
from the normal suite:

```sh
IMV2_RUN_100K_DELIVERY_SOAK=1 \
  docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm \
  -e IMV2_RUN_100K_DELIVERY_SOAK=1 \
  -e V2_TEST_PACKAGES=IMV2Server \
  -e V2_SERVER_TEST_FILTER=drainsOneHundredThousandMemberAudienceExactly swift-tests
```

This is end-to-end delivery correctness evidence, not a throughput benchmark:
it uses one isolated PostgreSQL instance and does not represent concurrent room
writes, multi-replica workers, live sockets, Push, or production topology.

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
