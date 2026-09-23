# G2 concrete Room Host lifecycle against PostgreSQL

Base: `8178b6d194e42fc8008f80c467a974971853f5d7`. The new opt-in suite is
`IMV2Server/Tests/IMV2ServerTests/V2RoomHostPostgresLifecycleTests.swift`.
It uses the real `PostgresV2RoomActivationStore`, `V2RoomActivationHost`, turn
lane and `V2RoomServerActivationFactory.runtimeFactory()`. The wrapper around
the concrete factory only inserts deterministic barriers immediately before
`restore` or `close`; it forwards all actual restore, execute and close calls.
Each test installs the canonical schema and seeded room in its own disposable
PostgreSQL 16 database, then drops the schema and closes its pool.

| Case | Injected phase | Observed invariant |
| --- | --- | --- |
| Restore loses its lease | After real acquire, before concrete `restore`: release the old token and acquire a successor epoch in PG. | Old Host never publishes ready, its pending/retiring state clears, its conditional old release cannot remove the successor, and a later concrete restore obtains the next epoch and completes a real recovery query. |
| One shared waiter cancels | Two calls wait on one concrete restore; cancel only the first. | First returns typed `cancelled`, the other receives the originally acquired exact token, a real recovery query succeeds, waiter count and command permits return to zero, and stop releases the PG lease. |
| Restore saturation and idle handoff | A second room occupies the one restore slot while the first is already ready; a third activation exceeds the two-room bound. Later hold the second room's idle close callback. | Third request returns typed `overloaded` without a PG lease; the healthy room serves a real recovery query and has no leaked permit. While idle close is held, a new request for that room is `retired` and PG still holds its old token. After close, the new activation gets exactly the next epoch; old release is false and PG keeps the new token. |

The suite is enabled only by
`IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE=1`; the test also checks this flag
before installing or dropping the schema. It refuses a database that already
contains `im_v2`.

```sh
docker --context colima-imv2-vapor5 run -d --rm --name imv2-va-g2-host-pg \
  -e POSTGRES_PASSWORD=g2_probe -e POSTGRES_DB=g2_probe \
  -p 127.0.0.1::5432 postgres:16-alpine
# This run allocated 127.0.0.1:32798.
cd /Users/yyl/.codex/worktrees/virtual-actor-p0/IMMonorepo/IMV2Server
IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE=1 \
IMV2_ACTOR_HOST_G2_DATABASE_URL=postgres://postgres:g2_probe@127.0.0.1:32798/g2_probe \
swift test -j 2 --filter V2RoomHostPostgresLifecycleTests
```

The first native `-j 2` build took 38.14 seconds and all three PG cases passed
in 8.497 seconds. An independent `--skip-build` repetition passed 3/3 in
15.228 seconds. After the final ready-set and disposable-database assertions,
the latest source rebuilt in 32.23 seconds and passed 3/3 in 14.720 seconds.
All three commands exited 0. Logs are under
`/Users/yyl/.codex/virtual-actor-builds/g2-host-native/`.

This proves Host and concrete Server factory state transitions against PG
authority, without starting Cluster or Vapor processes. It does not inject an
OS process crash, DB connection outage, or a full hot-command queue, and it
does not claim the entire 21-case fault matrix is complete.
