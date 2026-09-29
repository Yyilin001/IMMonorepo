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

## Extraction order used

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
- The 404-line group-join quota, crash-recovery, and invitation-cancellation
  scenario group now has its own integration test shard. Its test bodies and
  serialized suite identity are unchanged.
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
- Scalar and ordered-batch direct first-message projection writes now share a
  borrowed-connection component with their input and result row decoders. The
  Store still owns the acceptance transaction and publishes cache changes
  only after commit.
- Ordinary direct room-log batch persistence now executes in its own component
  after the Store validates input ordering and direct memberships on the same
  transaction connection. Its SQL and cardinality checks are unchanged.
- Scalar persistence (group event, rich direct room-log, and plain direct
  adapter) is in an Infrastructure extension that receives the Store's transaction
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

The PostgreSQL-backed room-write suite passed after the finished path
extractions (342 tests, 1,482 seconds), including the multi-database and
subprocess SIGKILL recovery cases. Targeted database tests also passed after
each move; the scalar acceptance move passed owner-fence, COMMIT-uncertainty,
forward recovery, authorization-proof, and eight SIGKILL recovery cases. The
suite stays serialized because tests reuse schema names. All five server and
probe products from the CI release-build matrix compiled on Linux with Swift
6.4 and the pinned CI base image. This was a local reproduction of the CI
build, not a remote CI run. SwiftPM still warns about the pre-existing local
and remote `postgres-nio` package-identity conflict; dependency changes are
deferred separately.

After the forward inbox stage extraction, the four focused PostgreSQL tests
covering 21 owner-fence, acceptance/recovery, rejection, and direct-finalization
cases passed, as did all eight direct/forward authorization SIGKILL cases.
After the direct-policy row move, four focused PostgreSQL tests covering 11
policy-fence, revision, cache, and stranger-quota cases passed.
After the room/admission row move, four focused PostgreSQL tests covering five
scalar, hybrid-batch, direct-room-log, and activation-fence cases passed.
After the shared mutation-row move, the scalar and direct-room-log PostgreSQL
tests passed (three parameterized cases).
After the direct projection move, five PostgreSQL tests covering 11 warm
authorization, timestamp, cache, room-log, and stranger-policy cases passed.
After the group-join scenario move, all six affected PostgreSQL tests passed,
including the subprocess SIGKILL recovery cases.

The remaining private row decoders are consumed only by Store-owned
coordination or policy writes. Path-shared decoders have been isolated, and
test-only assertion rows and doubles remain beside their specific scenarios.
The complete PostgreSQL suite and local reproduction of the CI Linux release
build both pass. No compile-time or hot-path latency improvement is claimed:
those measurements were not part of this behavior-neutral extraction.

## Current module layout and remaining acceptance

The physical module move places the [Store](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2RoomWriteStore.swift)
and its SQL paths in `IMV2ServerInfrastructure`. The Store still selects the
owner and activation scope, owns the acceptance transaction and authorization
receipt, and returns committed results. The
[transaction coordinator](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteTransactionCoordinator.swift)
uses the Store's connection and finishes authorization proofs before commit;
the [commit-effects component](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteCommitEffects.swift)
publishes caches and command credits only after a Store-owned commit.

The [direct batch path](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteDirectBatchPath.swift)
now performs locked policy, message, and projection writes on that borrowed
connection for both the batch and warm direct path. Its
[policy context](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteDirectPolicyContext.swift)
maps the locked control and local policy facts. The
[forward inbox path](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteForwardInboxPath.swift)
keeps inbox, operation, then room lock order across preflight, acceptance, and
completion. Scalar and hybrid paths remain separate Infrastructure units.

[Owner selection](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteOwnerSelection.swift)
now keeps routes, activation and forward source together with restricted
construction. Same-room forwarding and activation without an explicit route
remain supported. [Control resolution](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteControlResolution.swift)
distinguishes unresolved reservations from prepared results, including an empty
grant set. The Store retains the transaction and receipt ownership boundaries.

The module move and focused checks do not close the outstanding lifecycle
and performance fault acceptance. The scoped rich/direct batch failure
matrix, multi-owner fault cases, and measured hot-path latency and compile-time
comparison still need their dedicated verification before any performance or
fault-tolerance claim is made for this layout. The PostgreSQL and Linux results
above describe the earlier extraction checkpoints.

## Scalar transaction boundary completion (2026-09-29)

The Store's scalar entry now only unwraps the borrowed SQL connection and
calls `V2RoomWriteScalarAcceptancePath`. This concrete component receives owner
and control selections, the direct policy context, stranger and review policies,
and a Boolean indicating whether to report admission heat. It has no Store,
cache publisher or command-credit pool reference. Its result still carries the
cache updates and heat observation for the existing post-commit owner.

`V2RoomWriteScalarPersistencePath` performs scalar persistence with explicit SQL
and review-mode inputs. Single-message direct projections use the same borrowed-
connection component as batch projections. `V2RoomWriteSelectedOwnerGuard`
centralizes the existing operation-lock, authorization-proof and owner/activation
checks for both Store and scalar callers. The unused `acceptHotDirectRoomLog`
entry has been removed; live fast and batch paths remain unchanged.

The complete Infrastructure source retains the same multiset of 743 multiline
SQL literals as candidate `c1944b1a103b121cc73b36beceb5348cc465fc88`.
This source comparison supports a code-movement review; it does not prove
runtime equivalence. Per the user's current scope, this step compiles products
and test targets without running database, process-fault or performance tests.
