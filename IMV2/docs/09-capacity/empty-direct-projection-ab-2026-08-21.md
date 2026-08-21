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
| Warm established rooms | 1,100 msg/s | 73,152 | 68 / 339 / 686 ms | 192 | 0 calls |

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

The load generator now accepts a controlled target up to 10,000 msg/s.  This
is only a test-tool input bound; it does not relax Gateway/database admission,
the local RSS/CPU guard, or the configured failure threshold.  The 1,100
msg/s run is therefore a valid overload observation, but it is not stable:
its 192 retryable `room_event: SERVER_BUSY` responses place the current
single-host steady-state boundary at 1,000 msg/s for this workload.

## Rejected read-queue experiment

The direct cause of the 1,100-msg/s rejection was the bounded interactive
room-log-read queue (384 waiting reads), not a rejected foreground message
write.  A temporary 768-item queue experiment removed the explicit read
rejections, but did not increase sustainable service:

| 1,100 msg/s setting | Busy responses | Client-skipped sends | Message P95 / P99 | Room-log P95 / P99 |
| --- | ---: | ---: | ---: | ---: |
| Default 384-item read queue | 192 | 564 | 339 / 686 ms | 515 / 1,387 ms |
| Temporary 768-item read queue | 0 | 3,193 | 506 / 2,485 ms | 575 / 3,251 ms |

The larger queue merely retained the overload until per-device in-flight
limits applied.  It was removed from the running Gateway and is intentionally
not retained as a deployment overlay.  Bounded early backpressure is the
correct behavior here; throughput requires reducing per-message PostgreSQL
work or adding physical write capacity, not accumulating more waiting reads.

## Recovery versus steady-state test hygiene

The load generator now supports `--room-log-initial-cursor tail`. It opens the
same direct rooms, obtains an authorized high watermark one room at a time per
simulated device, and only then begins the fixed-rate workload. The default
remains `zero`, which deliberately exercises full durable cursor recovery.
Retryable subscription backpressure uses a bounded per-room exponential retry
budget; it never silently starts at cursor zero.

This separates an initial history catch-up from the steady phase. It is
important because reusing a long-lived test database with a zero cursor makes
later runs read all historical room events and cannot be compared to a client
that is already caught up. The tail barrier itself is a startup phase, not a
claim that initial sync is free.

An 8-write / 4-control-write / 20-read admission experiment was also rejected
and removed. The direct append batcher has at most eight in-flight database
transactions, but moving its unused reservation to reads did not make the
1,100-msg/s mixed test stable: 583 bounded interactive-read rejections
remained. This establishes that the next bottleneck is combined service work,
not merely an incorrectly sized idle reservation.
