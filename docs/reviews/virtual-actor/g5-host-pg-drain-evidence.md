# G5 Host drain with a real PostgreSQL transaction

Base: `9565f1437413fbc33410dce5a351cb51b2263133`. The new opt-in test is
`IMV2Server/Tests/IMV2ServerTests/V2RoomHostPostgresDrainTests.swift`.

## Fault-matrix review and selection

The 21-case matrix in `IMV2/docs/00-foundation/virtual-actor-task-cards.md`
includes restore failure/lease loss, shared-waiter and command cancellation,
query/reservation interleaving, opposing pair reservations, and SIGTERM/drain
timeout. The Host and reservation tests already cover these scheduling states
with controlled fake lease stores/executors; the recovery-batcher tests cover
granted-turn batching and timer cleanup. The P0 process probe covers SIGTERM
resource order with a simplified Cluster/Vapor/PG process. None of those tests
held a **production Host turn's activation-fenced PostgreSQL transaction**
through a drain timeout and checked the real lease's handoff order. This was
selected as the bounded next gap because an early release would let a successor
obtain a new epoch while the old transaction was still in progress.

## Test and observed order

The test uses a disposable PostgreSQL 16 database and an isolated schema. Its
lease store is `PostgresV2RoomActivationStore`; scheduling and retirement use
`V2RoomActivationHost` and its real turn lane. A small test executor uses the
production `v2WithRoomScopedTransaction` and `v2RequireRoomActivation` helpers.
It pauses after the full token fence has locked the room row and before the
durable `room_sequence` update and COMMIT.

1. The Host activates and grants one token; its turn enters the fenced SQL
   transaction.
2. `drain` expires after 60 ms. It reports one remaining room, the Host has
   stopped publishing ready tokens, the executor has not closed, and the
   PostgreSQL lease row still contains the exact token and future expiry.
3. Releasing the transaction barrier commits one sequence increment. While the
   executor's close callback is held, another host's real `acquire` returns
   `occupied` with the old token.
4. Releasing close lets drain finish and conditionally release the old lease.
   The successor then acquires exactly the next activation epoch; an old-token
   release is false and the Host command budget returns to zero.

Run commands (exit code 0 for all three test runs):

```sh
docker --context colima-imv2-vapor5 run -d --rm --name imv2-va-g5-drain-pg \
  -e POSTGRES_PASSWORD=drain_probe -e POSTGRES_DB=drain_probe \
  -p 127.0.0.1::5432 postgres:16-alpine
# This run allocated 127.0.0.1:32794.
cd /Users/yyl/.codex/worktrees/virtual-actor-p0/IMMonorepo/IMV2Server
IMV2_ACTOR_HOST_DRAIN_DATABASE_IS_DISPOSABLE=1 \
IMV2_ACTOR_HOST_DRAIN_DATABASE_URL=postgres://postgres:drain_probe@127.0.0.1:32794/drain_probe \
IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 \
swift test -j 2 --filter V2RoomHostPostgresDrainTests
# Repeated with --skip-build and the same environment.
```

The first native build took 112.42 seconds; the single PG test passed in
1.696 seconds. The second run passed in 1.926 seconds. After tightening the
test's failure-path gate cleanup, an incremental rebuild took 25.61 seconds
and the latest source passed in 1.552 seconds. Logs are in
`/Users/yyl/.codex/virtual-actor-builds/g5-host-drain-native/first.log` and
`repeat.log` and `final.log`. The PostgreSQL container is disposable and is removed after
verification. No root Linux build cache or existing application database was
used.

This is Host/Runtime/PG drain evidence, not a delivered OS signal or a full
Vapor shutdown test. The executor is deliberately small so the SQL and close
phase barriers are deterministic; the test does not exercise every concrete
RoomDomain handler. The remaining SIGTERM process/lifecycle and query/pair
interleaving matrix cases still need end-to-end fault probes.
