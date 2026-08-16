# Greenfield legacy cleanup plan

Status: active
Scope: the entire repository
Compatibility policy: the project is not deployed; historical schema, wire,
configuration, and test-double compatibility is intentionally unsupported.

This document is the executable inventory for the cleanup. A row is complete
only when its implementation, tests, scripts, and documentation all express
the current contract and the listed local evidence passes.

## Cleanup inventory

| ID | Area | Current evidence | Required cleanup | Validation | Status |
| --- | --- | --- | --- | --- | --- |
| L01 | Production target contents | Four `InMemoryV2*Store` implementations under `IMV2Server/Sources` are referenced only by tests. | Move them into the server test target and remove their public API surface. | Server package build plus affected unit tests. | Complete — 32 focused tests pass |
| L02 | Gateway authentication | `V2GatewayAuthenticator` exposes split authentication/expiry reads and a default combined method retained for old fakes. PostgreSQL already implements an atomic combined read. | Keep only `authenticateSession`; route HTTP and gateway callers through the same atomic contract; update every fake explicitly. | Gateway, HTTP route, revocation, and integration tests. | Complete — one atomic contract; 41 focused tests pass |
| L03 | Protocol test-double defaults | Fan-out, room-outbox, read-receipt, profile projection, conversation paging, shard migration, live activity, and client runtime protocols contain no-op, fail-later, unbounded, or per-row defaults described as fake compatibility. | Remove compatibility defaults. Make required semantics protocol requirements and implement deliberate test doubles or named no-op adapters where absence is a real capability. | Compile every package and run focused suites for each protocol. | Complete — all requirements explicit; server/client/iOS focused suites pass |
| L04 | Public identity decoding | Core, HTTP, direct-room, and SQLite decoders silently turn a missing/invalid `accountKind` into `.regular`; constructors also rely on a default. | Require the current field everywhere, reject malformed/partial identity rows, and make call sites state `.regular` explicitly. | Core Codable, client HTTP, direct-room, profile, SQLite constraint, and app tests. | Complete — required across database, HTTP, protobuf v19, SQLite, and constructors; focused suites pass |
| L05 | Room roster identity | Roster identity is optional and PostgreSQL uses a `LEFT JOIN` solely for rows created before the profile migration. | Define current inactive-profile behavior, require identity for every returned active member, and remove optional wire/client handling. | Roster service, PostgreSQL integration, protobuf, and app member-list tests. | Complete — visible rows require active account/profile identity; hidden or disabled members are omitted; package, PostgreSQL, protobuf, and iOS tests pass |
| L06 | Room delivery state | SQLite overloads nullable `delivery_mode`: old records may omit it, but `NULL` also currently marks a hybrid room deactivated after `FORBIDDEN`. | Split current authorization/activity state from delivery mode, then make delivery mode mandatory for active room profiles. Do not delete the current deactivation behavior without replacement. | Sync projection, forbidden subscription, restart, and room-list tests. | Complete — delivery mode is required and immutable; independent durable event authorization stops forbidden pull/subscription loops, survives restart, and is restored only by a newer projection; 197 client tests and focused iOS tests pass |
| L07 | Client SQLite schema | `GRDBV2LocalSyncStore` registers dozens of sequential migrations containing `ALTER`, backfill, interrupted-table recovery, legacy-index deletion, and SQLite-version compatibility triggers. | Derive the final schema from a fresh migrated database, replace the chain with one current schema migration, preserve all current constraints/indexes/triggers, and replace migration-compatibility tests with fresh-schema contract tests. Existing client databases are intentionally unsupported. | Fresh database creation, schema snapshot comparison, all client/app tests, constraint probes. | Complete — one canonical primary schema and one derived-search schema; unused primary FTS and compatibility triggers removed; 161/5-object fingerprints, constraint probes, 198 client tests, and focused iOS tests pass |
| L08 | PostgreSQL schema | `IMV2/sql` contains 51 numbered migrations and mutable-history manifest/baseline locks; several scripts replay or marker-track old SQL. | Materialize one canonical bootstrap schema from the current final database; delete numbered history, marker ledger, manifest/baseline locks, freeze/check scripts, and old-namespace migrations. Existing database volumes are intentionally unsupported. | Bootstrap a disposable PostgreSQL instance, readiness coverage, full server integration, schema-drift check. | Complete — one canonical clean bootstrap; 119 tables, 283 indexes, 4 triggers, and 4 functions match a normalized `pg_dump`; readiness and all 323 PostgreSQL integration tests pass |
| L09 | Local stack configuration | `run_v2_local_account_stack.sh` silently appends keys to older `.env.local` files and migrates retained PostgreSQL volumes. | Generate only the current configuration contract. Validate an existing file as a whole and fail with an explicit reset/regeneration instruction; never silently upgrade it. Detect stale database schema and require an explicit local reset. | Shell tests plus clean and stale local-stack scenarios. | Pending |
| L10 | Migration verification gates | Swift/local verification invokes SQL manifest, frozen-baseline, local marker, and migration-rerun tests. | Replace historical gates with canonical schema integrity, clean bootstrap, readiness table coverage, and fresh SQLite schema checks. Keep generated-protobuf, runtime-env, metrics, integration, and iOS gates. | `scripts/run_v2_swift_tests.sh`, isolated test runner, and `scripts/verify_v2.sh` locally. | Pending |
| L11 | Historical names and comments | Retired device cursor namespace, V1-only comments, “legacy route” negative tests, probe text `protocol v1 verified`, and stale compatibility wording describe deleted evolution rather than the current system. | Delete obsolete negative tests and migration-only names; rename current concepts without changing protocol-version fencing or TLS terminology. | Repository scan plus focused tests. | Pending |
| L12 | Historical status documents | `implementation-status.md`, `implementation-review-and-roadmap.md`, `10-round-code-analysis.md`, and historical benchmark sections duplicate chronological work logs and contradict current implementation. | Replace them with a concise current implementation/evidence matrix and active roadmap; delete superseded audits and benchmark history after carrying forward current risks and reproducible commands. | Documentation links and command references resolve; repository scan has no superseded claims. | Pending |
| L13 | Architecture and operations documents | Root/server READMEs, ADR-000, ADR register, capacity contract, and residual-risk register still require append-only migrations or refer to closed work. | Rewrite them around canonical greenfield schema, current local-only verification, and genuinely open external risks. Retain current accepted ADRs and operational runbooks. | Documentation link check and cross-document consistency review. | Pending |
| L14 | Final residue audit | Compatibility signals are distributed across comments, tests, SQL, shell, Swift defaults, and docs. | Re-run semantic searches and inspect every remaining match; classify legitimate current history/timeline concepts separately from compatibility code. | No unexplained compatibility fallback, old migration mechanism, or obsolete document remains. | Pending |

## Deliberate non-cleanup boundaries

The following are current product mechanisms and are not historical
compatibility merely because they include versions, fallback paths, or old
events:

- Online user-shard migration, forwarding, rollback, and read fallback are
  current scaling and disaster-recovery capabilities.
- Snapshot schema/generation fencing and unknown protobuf-enum rejection are
  current protocol-safety mechanisms.
- Conversation timeline history is user data, not implementation history.
- Direct-room provisional local identity is current immediate-UI state until
  the authoritative projection arrives.
- Password fallback is the accepted account-factor policy.
- TLS 1.3 and named content-provider/ruleset versions are current versioned
  contracts.
- GitHub Actions configuration remains valid even while hosted Actions quota
  is unavailable; required verification is run locally.

## Execution order

1. Remove production-shipped test support and protocol compatibility defaults.
2. Tighten wire/domain models and separate overloaded current state.
3. Squash the client SQLite schema and replace migration tests.
4. Materialize the canonical PostgreSQL schema and replace migration tooling.
5. Simplify local configuration/bootstrap behavior.
6. Rewrite or delete historical documents after carrying forward current
   contracts and risks.
7. Run all local gates, rescan the repository, and close every inventory row.
