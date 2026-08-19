# Direct-send policy cache rollout

This change reduces repeated direct-message authorization reads without making
cache state authoritative. PostgreSQL remains the source of truth for every
accepted message.

## Deploy order

1. Apply `IMV2/sql/migrations/20260819_direct_send_policy_cache.sql` while
   the current gateway remains on the old binary. The backfill reads existing
   direct-room messages once and is safe to repeat.
2. Verify the new pair columns and policy-version table exist.
3. Deploy the gateway binary. A cold cache uses the complete authorization
   path; no warm-up task is required.
4. Observe cache hit/miss and authorization rejection metrics before raising
   load. Do not remove the database revision checks.

## Safety invariants

- Every fast-path policy value is fenced by the pair revision and both user
  policy revisions in the same PostgreSQL transaction.
- Pair-local changes (friendship and block changes) increment
  `direct_policy_revision` while the send path holds that pair row.
- User-wide changes (stranger-message preference and account disable) advance
  `user_direct_send_policy_versions`.
- A version mismatch falls back to the authoritative query; it can never turn
  a stale cache entry into an accepted message.
- `has_replied` changes only from false to true and is updated atomically with
  the first accepted message from that user.

## Rollback

Rolling back only the gateway binary is safe after the migration: old code
ignores the additional columns/table. Do not drop the new data until every
gateway replica has been rolled back and the database backup policy permits
the destructive change.
