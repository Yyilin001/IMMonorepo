# Empty direct-projection fast-path verification (2026-08-21)

## Scope

This note records a single-host validation of commit `9c8de4fb`.  It is an
implementation verification, not a production capacity commitment.

The direct room-log append path previously ran a data-modifying CTE after
every accepted batch to *discover* whether a first-contact profile or sending
capability projection was needed.  Once both markers existed, that CTE could
not insert a row, but it still consumed a PostgreSQL statement, transaction
CPU and connection occupancy.

The new guard skips the CTE only when every append in the already-accepted
batch has durable markers proving that neither projection can be created.  A
batch containing even one first-contact case retains the original all-or-
nothing CTE.  The preflight reads its direct-pair state from PostgreSQL in the
same transaction; the process cache is never an authorization authority.

## Test host and workload

- one ARM64 8-vCPU / 16-GiB host; PostgreSQL 16 and one Gateway;
- durable PostgreSQL defaults remain enabled (`fsync`, synchronous commit and
  full-page writes);
- public TLS, 1,500 client connections, 128-byte plain direct messages;
- room-log direct delivery, 32-item append cap, 2-ms normal / 20-ms sustained
  batching delay, 32 command credits, content review disabled;
- one room-log pull for each sent message and no sync pull workload.

The database was intentionally retained between the first and warm run, so
only the statement-level result is an exact before/after comparison.  It must
not be used as a clean-database production-sizing claim.

## Evidence

| Phase | Target | Message ACK | Message P50 / P95 / P99 | Retryable room-event busy | Post-accept projection CTE |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before change | 950 msg/s | 63,407 | 66 / 881 / 1,353 ms | 245 | 7,189 calls, 6.76 s |
| First run after change | 950 msg/s | 63,363 | 43 / 774 / 1,167 ms | 173 | 509 calls, 2.82 s |
| Warm established rooms | 950 msg/s | 63,640 | 48 / 302 / 821 ms | 8 | 0 calls |
| Warm established rooms | 1,000 msg/s | 67,068 | 58 / 313 / 653 ms | 0 | 0 calls |

At the 1,000-msg/s run, the top write SQL remained the authorization/room
preflight (8,077 calls, 10.54 s total, 1.305 ms mean), followed by canonical
message persistence (10,374 calls, 9.05 s total, 0.872 ms mean).  The removed
projection CTE no longer appeared in `pg_stat_statements`.

## Interpretation and next boundary

This change eliminates a real steady-state PostgreSQL statement but does not
remove the canonical durable message append.  In particular, room ordering,
idempotency, active membership, mute state, direct-pair state and policy
revision fences remain transactionally checked before acknowledgement.

The next material single-node improvement cannot safely be obtained by making
those authorization checks cache-only.  It requires an explicit design change:
one minimal canonical event/outbox transaction on the acknowledgement path,
then idempotent asynchronous materialization of user-facing derived state.
For direct room-log traffic, retain the current per-room event cursor as the
recovery source and move only non-canonical side effects behind the outbox.
