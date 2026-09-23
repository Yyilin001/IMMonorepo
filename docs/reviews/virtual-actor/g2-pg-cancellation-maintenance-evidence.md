# G2 PostgreSQL cancellation and maintenance handoff evidence

This opt-in suite runs the production `V2RoomActivationHost`,
`V2RoomServerActivationFactory`, owner resources, PostgreSQL activation lease,
send batcher, and maintenance retention store. It uses a disposable database.
The only test instrumentation is a temporary PostgreSQL trigger that waits on
a test-owned advisory lock after the production transaction has acquired its
room activation fence. The schema is dropped after each case.

## Run

Start an independent PostgreSQL 16 container with an ephemeral local port:

```sh
docker --context colima-imv2-vapor5 run -d --rm \
  --name imv2-va-g2-cancel-maint-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=imv2_va_g2_cancel_maint \
  -p 127.0.0.1::5432 postgres:16-alpine
docker --context colima-imv2-vapor5 port imv2-va-g2-cancel-maint-pg 5432
```

From `IMV2Server`, replace `<port>` with the returned port:

```sh
IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE=1 \
IMV2_ACTOR_CANCEL_MAINT_DATABASE_URL='postgres://postgres:postgres@127.0.0.1:<port>/imv2_va_g2_cancel_maint?sslmode=disable' \
swift test -j 2 --filter V2RoomHostPostgresCancellationMaintenanceTests
```

Observed on 2026-09-24 with host Swift 6.4, PostgreSQL 16, port `32810`:
the command exited `0`, with both tests passing. Final source log:
`/Users/yyl/.codex/virtual-actor-builds/g2-pair-native/cancel-maint-verified.log`.

Without `IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE=1`, the tests are
disabled. The suite refuses a database already containing `im_v2` and never
uses another project's container or database.

## Checked schedules

1. A normal send is admitted through Host, Factory, one physical send batch,
   and PostgreSQL, then blocks inside `messages` INSERT after the activation
   fence. A second send queues in the same room and is cancelled: its
   completion row stays absent and its command permit returns. Cancelling the
   first caller yields `outcomeUnknown`, while its physical SQL permit and
   lease remain held. A short drain cannot release the lease. Unlocking the
   insert allows one durable completion; after drain, a successor epoch
   replays the same client operation ID to the original message ID, with no
   duplicate completion. This is caller cancellation, **not** simulated
   network COMMIT ACK loss.
2. A production `.maintenance(.trimLog)` turn blocks inside the event DELETE
   after the exact-token fence and floor update. A second production Host
   tries to activate that room and waits on the canonical `rooms` lock. An
   unfenced MVCC observation sees the old committed floor and all events.
   Releasing the trigger permits retention to commit its floor and two
   deletions; the contender can only observe the old occupied lease then.
   After the first Host closes, the second Host acquires epoch + 1. The old
   Host invocation, conditional lease release, and direct production retention
   executor with the old token are all rejected; the new token's retention
   turn is a no-op.

The fixture deliberately uses plain MVCC reads for paused-state assertions.
Calling the production `leaseStore.locate` while a writer holds the `rooms`
lock would queue a second authority operation and alter the schedule under
test. The takeover itself uses the production locking acquisition path.

Native Swift 6.4 Debug exercises real PostgreSQL transactions and Host paths;
this suite is not a Linux Release or multi-process transport test. The other
G2/G5 suites cover those separate dimensions. PostgreSQL `lock_timeout` and
`statement_timeout` retain their production defaults in the exercised stores.

## Review and import critical-point handoff

The suite was extended to four cases at agent commit `00fd5a76aa9df8895fba927857084ec04974ebf2`, integrated as `d4f173df`. Native Swift 6.4 and a fresh task-only PostgreSQL 16 ran all four serially with `--no-parallel --filter V2RoomHostPostgresCancellationMaintenanceTests`: **4/4 passed, exit 0**. The final log is `/Users/yyl/.codex/virtual-actor-builds/p0/maintenance-takeover-native/final.log`; the schema and container were removed. The first attempt exposed a fixture error: the production send store had already created the review job, so the extra test INSERT conflicted. `attempt1.log` preserves that failure; the duplicate fixture INSERT was removed, and both `attempt2.log` and the final run passed.

The review case uses `V2ContentReviewWorker`, its typed safety applicator, and a real Host/Factory trusted-safety turn. A PostgreSQL trigger holds the `moderation_operations` INSERT after the activation fence. While the second Host's acquisition is observably blocked (`pg_blocking_pids`), the review job has no completion and the redaction is not committed. Releasing the fence commits one terminal job and one event; the first Host then drains, and the successor acquires epoch + 1. Old-token dispatch is rejected and new-token replay is idempotent. A second real review job sent to the retired Host remains pending with its claim released; the successor's worker completes it on retry.

The import case prepares a real source export for a separate logical shard, then invokes target `.forward(.importExport)` through the production Host/Factory. A trigger holds target inbox receive under its activation fence; a second Host cannot acquire that target until the transaction settles. After completion and drain, the successor epoch replays the original export to the same message ID and sequence, with exactly one inbox, target message and completion. The source is a fixture on the same PostgreSQL instance; this proves the target owner's critical-point handoff, not a new cross-process or cross-database transport scenario.

These two new cases have native real-PostgreSQL evidence. Their Linux execution remains part of the pending final full-suite gate; the earlier Linux runs only contained cancellation and retention.
