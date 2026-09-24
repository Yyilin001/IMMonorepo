# D3 query and receipt executor evidence

The room-side adapters use the physical owner PostgreSQL database. `V2ActorRoomQueryExecutor` validates every exact activation token in the same transaction as a log, directory, or recovery read. Recovery state and latest-visible queries call the existing collection stores once for the complete room set. It does not use the optional process event cache as read authority.

`V2ActorRoomReceiptExecutor` handles record, reader query, and already-granted record batches. The receipt store sets SQL timeouts before its first lock, takes room locks in canonical order, checks the full activation after those locks and before advisory locks or replay reads, and classifies COMMIT failures as unknown. A batch maps only explicit room-not-found or owner mismatch to that row's `ownerChanged`; SQL, connection, and lock failures abort the transaction. Invalid rows cannot inspect replay records or write receipt state. Legacy owner-route entry points remain available.

`V2HostRoomRecoveryQueryBatcher` is scoped to one owner database and accepts only independently granted room turns. Its turn constructor is internal to `IMV2Server`; Runtime must pass both the original monotonic `batchDeadline` and separate end-to-end `callDeadline`, then release each turn independently. An elapsed batch cutoff dispatches a live call immediately; only the call deadline expires it. It groups by user and query kind, bounds items, request and response bytes, pending items, and in-flight batches, and propagates an uncertain query outcome to all participating turns. It never acquires room admission or waits for another grant while holding a SQL lock. At full in-flight capacity, incompatible new epochs or items that would exceed a pending batch limit are rejected as busy rather than merged into an unflushed queue.

Verification on an independent disposable PostgreSQL 16 database (`imv2-va-d3-pg`, port 32769), macOS Swift debug, `--jobs 2`:

| Command | Result |
| --- | --- |
| `IMV2_POSTGRES_TEST_DATABASE_URL=postgres://d3:d3@127.0.0.1:32769/d3 IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 swift test --jobs 2 --filter V2ActorRoomQueryExecutorIntegrationTests` | Exit 0; 5 real database tests: replay and old token, mixed old/new batch with zero stale writes, lock timeout infrastructure classification, collection/directory/log authority, granted-turn batching and deadline. |
| `IMV2_POSTGRES_TEST_DATABASE_URL=postgres://d3:d3@127.0.0.1:32769/d3 IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL=postgres://d3:d3@127.0.0.1:32769/d3_secondary IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 swift test --jobs 2 --filter receiptBatchTimestampPrecision` | Exit 0; 6 real database cases across scalar/mixed/group/owner paths and both capacity classes. |

Logs: `/Users/yyl/.codex/virtual-actor-builds/p0/d3-tests-final-latest.log` and `/Users/yyl/.codex/virtual-actor-builds/p0/d3-receipt-legacy-precision-real.log`. A first legacy invocation omitted the secondary database and returned via its test guard; it is not counted above.

Batcher deadline and saturation follow-up: the same isolated PostgreSQL command passed with 7 tests (exit 0), including a real database read whose batch cutoff had elapsed while its call deadline remained live, and deterministic phase-barrier tests for one occupied in-flight slot, pending call expiry, incompatible epochs, item capacity, and byte capacity. Log: `/Users/yyl/.codex/virtual-actor-builds/p0/d3-batcher-deadline-test.log`.

Integration boundary: the root total executor and Runtime factory will route these adapters. Gateway subscription delivery lifetime and control-side user-room enumeration are separate work. This branch does not run the full ServerTests suite or Linux Release.
