# Room write Store decomposition

`PostgresV2RoomWriteStore` is the PostgreSQL acceptance boundary for scalar,
forwarded, direct-room-log, and batch sends. The goal is to make those paths
reviewable without changing their persistence contract or public store API.

## Contracts to preserve

- The room write transaction owns authorization receipt completion. A message
  or durable denial and its authorization proof must commit or roll back
  together (`withRoomWriteTransaction*`).
- Selected owner and activation fences are checked on the transaction's
  connection. Room/admission lock order and multi-room deterministic ordering
  must not change while extracting code.
- Scalar and batch writes retain their existing replay and idempotency checks.
  The conditional shard reservation remains the final contended SQL update;
  rejection rolls back all earlier writes in that transaction.
- Process-local cache updates and command-credit commits occur only after
  PostgreSQL commit. A post-commit failure under an activation scope remains
  an unknown outcome, not a new acceptance attempt.
- Named prepared-statement SQL and names move unchanged. Changing SQL later
  requires a statement-name revision and separate behavior/performance review.

## Extraction order

1. Keep the serialized integration suite and move its reusable database and
   room-seed fixtures to a dedicated test-support file. Do not enable test
   parallelism while cases share disposable schema names.
2. Extract row decoders, pure conversions, and named prepared statements by
   write path. Keep the public Store and all transaction orchestration in one
   place. Promote file-private declarations only as far as `internal` when a
   cross-file reference actually requires it.
3. Extract scalar, fast direct-room-log, hybrid-group batch, and forwarded
   acceptance paths one at a time. Pass the borrowed transaction explicitly;
   a path component must not open its own transaction or finalize a credit.
4. Keep each move behavior-neutral. Review SQL text, statement names, retry
   classification, lock ordering, and post-commit effects in its diff.

## Verification for each step

- Compile and run the affected Swift package tests.
- Run PostgreSQL-backed acceptance/replay, owner-fence, direct fast-path,
  hybrid batch, forwarded import, and commit-uncertainty cases where the
  moved code participates. Multi-database and crash tests require their
  disposable service fixtures rather than a silently skipped local run.
- Build the server on the CI Linux toolchain. Measure compile time and hot
  send-path latency before claiming a performance improvement.

No schema migration, public protocol change, or deployment topology change is
part of this refactor.

## Implementation status

- Shared integration fixtures are isolated in
  `PostgresV2RoomWriteStoreIntegrationFixtures.swift`, including schema setup,
  default routing, projection queries, and completion/schema assertions that
  were previously embedded in the cleanup/invitation test shard.
- The ordered operation-lock statement and conditional hybrid-group statement
  are separate compilation units; their SQL text and statement names remain
  unchanged.
- The hybrid-group batch append now executes through a write-path component
  with a borrowed transaction connection. The Store still owns ordered
  request preparation, owner/activation fencing, mismatch diagnosis, transaction commit,
  and post-commit credit finalization.
- The hybrid-group batch's authoritative preflight SQL, named PostgreSQL
  statement, SQLKit fallback, and row decoder now live together in a borrowed-
  connection component. The Store still orders requests and owns all fencing,
  final admission reservation, commit, and credit finalization.
- Fast direct room-log append SQL and its row decoder now live in a direct
  write-path component. The Store still constructs validated inputs, acquires
  ordered operation locks, checks owner routes, owns the transaction, and
  finalizes credits after commit.
- The direct room-log hot path's authoritative pair/policy/member preflight
  and wide row decoder now live in a borrowed-connection component. Cached
  policy facts remain hints checked against locked durable revisions.
- Ordinary direct room-log batch persistence now executes in its own component
  after the Store validates input ordering and direct memberships on the same
  transaction connection. Its SQL and cardinality checks are unchanged.
- Scalar persistence (group event, rich direct room-log, and plain direct
  adapter) is in a same-module extension that receives the Store's transaction
  connection. Scalar replay, authorization, denial, and final shard reservation
  now execute in a dedicated acceptance-path extension on that borrowed
  transaction. The Store retains transaction creation, authorization receipt
  completion, and post-commit cache/credit finalization.
- The scalar acceptance preflight, its lock-bearing SQL, and its replay/context
  row decoders are isolated behind a borrowed-connection loader. The Store
  still selects the owner/activation fence before loading and controls all
  subsequent acceptance effects.
- Forward-source version/reference validation and message-media locking now
  share a transaction-borrowing media acceptance component. Forward inbox
  preflight, acceptance, and completion stages now live in a borrowed-
  transaction extension. The Store still owns the three transaction boundaries,
  authorization coordination, and post-commit cache/credit finalization.
- Direct-policy snapshot decoding and cache projection conversions now live
  beside the direct acceptance path. Their field mapping and post-commit
  publication rules are unchanged.
- Locked room, room-admission, and shard-admission snapshot row decoders now
  live together outside the Store. Their sequence bounds and lease-generation
  checks remain unchanged.
- The message mutation-count row shared by scalar and direct batch writes now
  lives beside those write paths. Six unreferenced private row decoders were
  removed; Store-local decoders still used only by Store orchestration remain
  private in the Store.
- The non-PostgresNIO SQL fallback remains behavior-neutral but is not exercised
  by native PostgreSQL tests. Do not count those tests as fallback coverage.

The PostgreSQL-backed room-write suite passed (342 tests, 1,398 seconds) before
the current path extractions. Targeted database tests passed after each move;
the scalar acceptance move also passed owner-fence, COMMIT-uncertainty, forward
recovery, authorization-proof, and eight SIGKILL recovery cases. The suite
stays serialized because tests reuse schema names. The CI Linux build has not
yet been run for the finished decomposition.

After the forward inbox stage extraction, the four focused PostgreSQL tests
covering 21 owner-fence, acceptance/recovery, rejection, and direct-finalization
cases passed, as did all eight direct/forward authorization SIGKILL cases.
After the direct-policy row move, four focused PostgreSQL tests covering 11
policy-fence, revision, cache, and stranger-quota cases passed.
After the room/admission row move, four focused PostgreSQL tests covering five
scalar, hybrid-batch, direct-room-log, and activation-fence cases passed.
After the shared mutation-row move, the scalar and direct-room-log PostgreSQL
tests passed (three parameterized cases).

Still to extract: remaining shared/path row decoders and larger integration
test fixtures.
Repeat the complete PostgreSQL suite and CI Linux build before declaring the
finished decomposition verified.
