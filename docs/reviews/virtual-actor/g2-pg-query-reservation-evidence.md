# G2 PostgreSQL query and pair reservation interleavings

Base: `b52ff79ba2433a2ea935cb4d114baadad2593052`. The opt-in suite is
`IMV2Server/Tests/IMV2ServerTests/V2RoomHostPostgresReservationTests.swift`.
It uses two rooms on one real PostgreSQL 16 owner, the production
`V2RoomActivationHost` and `V2RoomServerActivationFactory.runtimeFactory()`,
the shared production recovery batcher, `V2RoomReservationCoordinator`, and
`V2ActorForwardPairDomainExecutor`. The test only supplies phase barriers,
operation tracing and a synthetic completion-loss decision after one real SQL
commit. Both rooms are activated with complete PostgreSQL lease tokens.

| Matrix case | Phase order and database observation |
| --- | --- |
| #15, recovery query versus pair | A test transaction holds B's `rooms` lock. B's already granted recovery turn takes its Host read permit and waits at the production activation fence. The coordinator then obtains A's reservation and queues for B; A's recovery call queues behind that reservation. The Host budget has all four accepted permits while B's SQL is in flight. Releasing the test lock lets B's **independent** collection read return its pre-forward head, then the actual A→B forward transaction commits once, then A's query completes. The forward operation row and target head advance once, both read permits complete, and Host command budget returns to zero. B never waits for A's still ungranted read turn. |
| #16, opposing A→B/B→A pairs | The first pair holds both canonical reservations just before SQL. A reverse-direction pair attempts A first and is cancelled there: it never acquires B, never dispatches SQL, and its queued reservation permit is returned. A second reverse pair also attempts A first. After the first pair's real forward SQL commits, the second acquires A then B and its real forward SQL commits. The test then reports `outcomeUnknown` to the coordinator, modeling loss of the post-SQL completion notification. Both Host activations retire, release their PostgreSQL leases and all permits, and reacquire exact next epochs. Replaying the same pair operation through the coordinator returns its original message ID with one durable operation row. |

The test sets `maximumConcurrentReservations=4` while activating only two
rooms. Two permits belong to the held pair and a third can represent the
opposing attempt waiting on A. With a cap of two, the correct behavior is
immediate overload rather than a wait, so that setting would not exercise the
opposing-order case.

Run against a new disposable database; the suite checks the opt-in flag and
refuses a database that already contains `im_v2`:

```sh
docker --context colima-imv2-vapor5 run -d --rm --name imv2-va-g2-pair-pg \
  -e POSTGRES_PASSWORD=pair_probe -e POSTGRES_DB=pair_probe \
  -p 127.0.0.1::5432 postgres:16-alpine
# This run allocated 127.0.0.1:32804.
cd /Users/yyl/.codex/worktrees/virtual-actor-p0/IMMonorepo/IMV2Server
IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_IS_DISPOSABLE=1 \
IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_URL=postgres://postgres:pair_probe@127.0.0.1:32804/pair_probe \
swift test -j 2 --filter V2RoomHostPostgresReservationTests
```

The two cases passed together in 4.549 seconds, and an independent
`--skip-build` repeat passed in 8.192 seconds. After aligning the test executor
with each coordinator's original monotonic deadline, the latest source rebuilt
in 22.87 seconds and passed 2/2 in 6.448 seconds. All three runs exited 0.
Logs are under
`/Users/yyl/.codex/virtual-actor-builds/g2-pair-native/`.

The post-SQL unknown is deliberately injected **after** the real executor
returns a committed result. It proves Host/coordinator retirement and
reconciliation but is not a transport ACK-loss injection. The separate
COMMIT-ACK proxy tests cover that boundary. These tests do not start a second
OS process or prove every fault-matrix case.
