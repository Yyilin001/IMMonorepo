# Direct-send policy cache operations

This change reduces repeated direct-message authorization reads without making
cache state authoritative. PostgreSQL remains the source of truth for every
accepted message.

## Deploy order

1. Initialize an empty database with `IMV2/sql/schema.sql` and verify the current
   SQL contract and server readiness.
2. Start the current gateway. A cold cache uses complete authorization queries;
   no historical backfill or warm-up job is required.
3. Observe cache hit/miss and authorization rejection metrics before raising
   load. Keep the database revision checks enabled.

## Safety invariants

- Gateway binds every room writer to an independent control-policy pool, including
  the writers retained by foreground and background forward delivery.
- Ordinary, atomic-batch and ready forward direct sends read account, block/friendship,
  recipient preference and special-account facts under shared control locks,
  and commit a durable grant before entering any owner transaction. The full
  batch user/pair lock set is acquired in stable order during reservation.
- Owner pair/user revisions still fence the cached owner snapshot. They cannot
  certify freshness of a different database's control policy.
- Persisted control facts may leave the control transaction only bound to the
  exact command fingerprint, recipient, owner and generation. Owner transactions
  reject aborted grants and save their immutable proof with the message or
  business denial. Shared caches retain owner facts and cannot override control.
- Owner membership, mute, reply markers and admission remain checked by the
  existing owner transaction. Group-only writes use their existing owner rules.
- \`has_replied\` changes only from false to true and is updated atomically with
  the first accepted message from that user.
- Control and owner pools must be distinct even for one physical database.
  The direct-control pool is included in the process connection ceiling and
  exposed under the fixed metric class \`direct_send_control\`.

Social changes lock the local room before advancing its pair revision. A frozen
source copy is left unchanged; the configured destination uses fresh control
facts instead. Active colocated rooms retain their existing revision fence.

Automatic authorization now covers forward import as well. Complete process
failure, policy-writer coverage and room migration remain open. Normal
connection tests do not prove a distributed commit guarantee; see the
[governance contract](../../../docs/reviews/room-owner-migration-contract.md).

## Durable authorization runtime wiring

Gateway and Operator register separate authorization-resolution pools for each
unique control/room-owner database URL, with one connection per event loop.
Logical room aliases reuse that physical pool. These connections are included
in the process ceiling and never borrowed from policy-writer or reservation
pools. Owner abort commits before control acknowledgement starts, allowing both
to share a resolution pool when colocated.

Gateway wires the coordinator into social and stranger-policy writers; Operator
wires it into account disable. Gateway recovers at most eight due grants per
iteration, using the configured worker poll interval, and includes task cancellation in
the existing bounded shutdown drain before closing its databases. The fixed Gateway metric class is
`direct_authorization_resolution`.

Ordinary, atomic-batch and forward sends reserve and bind grants automatically.
Acknowledgement happens after owner commit and local admission-credit finalization;
a failure returns retryable UNAVAILABLE and leaves the durable grant for recovery.
No owner proof means no acknowledgement; absence never implies abort. Forward
import first completes a short inbox/media preflight transaction; media pending
returns without a grant. Reservation uses the stable ready-media command digest,
and acceptance revalidates that command and the owner in its own transaction.
Terminal replay returns the existing outcome and can acknowledge an existing
owner proof without payload decoding or a new authorization generation. Rejections
without a message proof retain their obligation for the bounded abort/recovery
worker. The old `withControlPolicies` callback has been removed from the room
writer. Full process lifecycle, concurrency faults and migration validation remain
open. Configuration
boundaries and coordinator drain/recovery with occupied single-connection
foreground pools passed for colocated and separate databases; see the
[verification record](../../../docs/reviews/verification-records.md#20260920-direct-authorization-runtime-pools).

## Deployment boundary

Historical schema upgrades and rollback to old authorization code are not supported.
Current-version restarts retain the database facts and rebuild the cache on demand.


Forward-specific verification covers ready and pending media, real file copying,
permission rejection, invalid text, admission retry, finalization and ACK failure,
and compacted terminal replay; see the
[forward authorization evidence](../../../docs/reviews/verification-records.md#20260920-forward-automatic-authorization).
