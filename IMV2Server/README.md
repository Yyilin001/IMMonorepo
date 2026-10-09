# IM V2 Gateway

`IMV2ServerApp` is a standalone V2-only TLS gateway. It has no external route,
table, wire-protocol, or migration dependency.

For the cross-component data path and the distinction between implementation
and release evidence, see [the current system map](../docs/current-system-map.md)
and the [V2 document entry](../IMV2/docs/README.md).

## Provisioning

The server package requires Swift 6.4 (macOS 26.2 or later on macOS) and pins
Vapor 5.0.0-beta.2. Linux images and CI use the same Swift 6.4 Jammy digest.
See [the Vapor 5 migration contract](../IMV2/docs/00-foundation/vapor5-migration.md)
for database ownership, shutdown order, dependency boundaries and validation.

1. Create an empty PostgreSQL database and install the single current schema:
   `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f IMV2/sql/schema.sql`. Before
   deployment, run `bash scripts/test_v2_postgres_schema_bootstrap.sh` against
   an isolated Docker PostgreSQL instance to verify clean bootstrap, the current
   structure contract, and schema export/restore equivalence. To use an existing
   PostgreSQL server instead, set `IMV2_SCHEMA_BOOTSTRAP_NATIVE=1` together with
   `PGHOST`, `PGPORT`, and `PGUSER` (and credentials if required); put PostgreSQL
   16 `psql` and `pg_dump` on `PATH`. The native check creates and removes two
   uniquely named test databases and requires permission to create databases.
   This unreleased project installs only the current schema; historical upgrade
   scripts and mixed-version deployment paths are removed.
2. Provision PEM certificate-chain and private-key files through the deployment
   secret store.
3. Provision a random 32-byte-or-longer access-token HMAC key as base64. The
   gateway persists only HMAC digests of high-entropy opaque access tokens.
4. Deploy the separately trusted account/device issuer with its own random
   32-byte ChaChaPoly replay-envelope key. It calls
   `V2PostgresDeviceCredentialService` after authenticating the account factor;
   the issuer's envelope key must not be present in the gateway process. A
   gateway never accepts a user ID from a client payload. Mount
   `V2VaporDeviceCredentialRoutes` only on that account-service listener after
   injecting its production `V2AccountAssertionVerifier`, TLS/rate-limit
   policy, edge-authorization and edge-client-rate-limit secrets, and secret
   provisioning; do not register those routes on the
   realtime gateway listener.
   The selected primary factor is a production WebAuthn verifier. The provided
   `V2HMACAccountAssertionIssuer` makes a 90-second, device-bound hand-off to
   the device issuer; it is not a passkey verifier itself. The fallback
   `V2PasswordAccountRoutes` stores Argon2id PHC verifiers and uses the
   bounded application password worker for same-cost unknown-account rejection.
   The account service also requires its own Push endpoint envelope key, used
   to encrypt the opaque APNs token at rest; do not place this key in the iOS
   app or a client-visible configuration file.
5. Provide `IMV2_ROOM_ACTOR_CONFIGURATION_FILE` for Gateway and Account. The
   Gateway can host rooms or use a caller-only identity; Account requires a
   caller-only identity. Provision each node's signing key, private CA trust and
   DNS-valid mutual TLS certificate using the [Room Virtual Actor contract](../docs/reviews/room-virtual-actor-contract.md).
   The local stack script creates isolated test identities automatically.
6. Set every required variable in [`.env.example`](.env.example), then run the
   V2 app. The `IM_V2_NATS_*` and `IM_V2_GROUP_WAKE_NATS_*` variables are
   all-or-nothing optional hint layers, not required broker dependencies.

Before packaging a deployment, verify that the three checked-in examples still
match their strict runtime constructors:

```sh
./scripts/check_v2_runtime_env_examples.sh
```

## Durable-work operator replay

`IMV2OperatorServerApp` is a separate loopback-only control-plane executable
for replaying one explicitly paused room-outbox or fan-out-delivery row at a
time. It has a dedicated bearer secret and principal, never shares the public
gateway listener, and writes replay audit evidence atomically with the state
transition. Configure it from
[`operator-replay.env.example`](operator-replay.env.example) and follow the
[operator replay runbook](../IMV2/docs/10-operations/durable-work-operator-replay.md).
Do not publish its port directly; use an approved bastion or mTLS operator
proxy.

## Account-factor service

`IMV2AccountServerApp` is a distinct, loopback-only process for account-factor
verification and device-credential issuance. It is intentionally not part of
the realtime gateway process. Configure it from
[`account.env.example`](account.env.example), apply the same V2 schema, then
start it with:

```sh
swift run --package-path IMV2Server IMV2AccountServerApp
```

Place a managed HTTPS reverse proxy in front of this loopback listener. The
proxy owns the public certificate and must overwrite the account-edge proof
and client-address headers before forwarding. The account process applies its
own cross-replica request budget after that authenticated boundary, so an
expensive route cannot be reached by a direct loopback caller. The iOS app
accepts only an HTTPS account base URL; it must never be pointed directly at
the internal HTTP listener.

The password factor uses Argon2id v19 (64 MiB, three passes, one lane), a
16-byte random salt and a 32-byte digest. Inputs are 12–1024 UTF-8 bytes;
NUL is rejected, with no trimming, normalization or truncation. The fixed
non-account dummy verifier uses the same policy; no dummy-hash environment
variable is required. One application-owned pool admits two KDF calls and
returns no-store 503/Retry-After on saturation; a cancelled running KDF retains
its slot until it returns. Unsupported/legacy bcrypt records receive the same
KDF work and cannot issue password assertions or be silently rehashed.
Existing records remain intact. This greenfield deployment must rebuild test
accounts or use independently trusted account recovery before resetting a
legacy password; knowing a bcrypt-equivalent prefix is insufficient.

Keep the
account assertion HMAC key and the device-credential replay-envelope key in
this service's secret scope only; neither belongs in the realtime gateway.
Password verification atomically debits the canonical-account attempt budget
in PostgreSQL before KDF work, shared across account-service replicas. Incomplete
attempts remain charged; a successful authentication resets the budget. Its maximum
failures, window and lockout duration are required `IM_V2_PASSWORD_LOGIN_*`
configuration values; a lockout returns no-store `429` with `Retry-After`.
The service also applies the required
`IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_*` fixed-window budget to every account
request after validating the edge proof and exactly one edge-generated client
address. PostgreSQL stores only a HMAC digest derived using the distinct
`IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64`, never a clear-text address;
expired windows are removed in bounded batches. The production ingress must
still supply an approved trusted-proxy chain and outer DDoS/abuse controls,
and production still requires approval plus drills for audit, recovery and the
implemented account-disable operator path.

The client-side passkey flow has a complete challenge/assertion transport
boundary, but this executable does not yet mount public WebAuthn endpoints:
doing so requires an audited server verifier plus one-time challenge storage.
Password fallback is the presently deployable initial-account path. Password
changes and offline recovery codes are available through Account Security; see
[the lifecycle contract](../docs/reviews/account-authentication-lifecycle.md)
for API behavior, assertion revisions, migration and verification.

Every account request must carry the base64 edge-authorization secret and one
valid client address injected by that same HTTPS proxy. The account process
rejects direct loopback requests, duplicate headers and malformed addresses
before rate limiting, so do not route around the proxy for probes or tooling.
The checked-in local Caddy configuration derives the address from its direct
peer and Caddy's normal reverse-proxy behavior discards client-supplied
`X-Forwarded-*` values. A production topology behind another L7 proxy must
explicitly configure and validate its own trusted-proxy chain; it must not copy
an arbitrary forwarded address into this header.

### Local native-client workflow

For development, keep the iOS app native and run only its account dependency
in Docker:

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
```

The script creates ignored local-only keys in `IMV2/.env.local`, starts
PostgreSQL, the account process, and the native V2 TLS gateway. It publishes
only `https://localhost:8443` plus TLS gateway `localhost:7443` on macOS
loopback. Caddy and the account process
share one container network namespace, so the account process still binds only
to `127.0.0.1:8444`; no database or internal HTTP port is published to macOS.
On first run, import the generated `IMV2/local-ca/root.crt` into the selected
iOS Simulator and enable full trust for it. The Debug app configuration already
uses `https://localhost:8443`. The helper prints the exact stop command and
never creates a Python virtual environment or modifies the host database.

The gateway performs a schema-readiness check before binding its TLS port. It
requires TLS 1.3 and rejects absent configuration rather than selecting
development defaults.

After the stack reports ready, verify the local HTTPS account factor,
device-credential hand-off and TLS gateway without printing any assertion or
credential:

```sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

The smoke check creates one uniquely named account in the local Docker volume;
it never contacts a public endpoint or writes a token to disk/output.
The same stack is exercised locally under an isolated Compose project; that
evidence remains local-stack coverage, not a production deployment approval.

## Operational notes

- `IM_V2_MAX_CONNECTIONS` bounds all accepted TLS sockets, including clients
  that have not authenticated. `IM_V2_MAX_FRAME_BYTES`, protobuf depth,
  in-flight requests, inbound queued bytes, and queued chunk count are hard
  per-connection bounds; queue pressure closes the connection and clients
  recover by sync.
- `IM_V2_AUTHENTICATION_TIMEOUT_MS` is an absolute accepted-to-authenticated
  deadline. Sending a slow stream of fragments cannot extend it. Successful
  authentication and connection admission end this deadline before subsequent
  commands in the same decoded batch execute.
- `IM_V2_IDLE_TIMEOUT_MS` closes a silent TLS session. Foreground clients send
  application-owned heartbeats; background clients rely on reconnect and sync.
  The deadline follows the last inbound byte, including incomplete frames; it
  is not a deadline for completing a command or assembling a frame.
- Foreground push authorization is checked again when queued frames are written.
  Expired authentication or a revoked connection invalidates pending fast-path
  frames; clients recover missing events through their durable room cursors.
- Shutdown first closes and drains connection work while its dependencies and
  event loops remain available, then drains workers and auxiliary services before
  releasing the event loops. Exceeding the configured shutdown grace fails the
  process instead of releasing resources beneath unfinished connection work.
- `IM_V2_WORKER_BATCH_SIZE` and `IM_V2_WORKER_POLL_INTERVAL_MS` bound and
  schedule the current durable workers, including personal-event projection,
  room wake, review, media and cleanup work.
- Gateway PostgreSQL work is split into explicit foreground, Sync, Delivery,
  Projection and Maintenance pools whose per-event-loop sum remains inside the
  legacy aggregate ceiling. A separate short admission queue returns retryable
  `SERVER_BUSY` before Fluent's longer pool timeout. Projection claim
  concurrency, accepted-message batch projection, Sync-hint coalescing,
  metrics, staged rollout and rollback are documented in
  [the single-node performance runbook](../IMV2/docs/10-operations/single-node-performance-rollout-runbook.md).
- Personal snapshots read their payloads directly from personal projection versions.
  Public content is recovered through room logs. Immutable room message states
  retain their own bounded compaction and garbage collection; the retention
  setting is `IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS`.
  See [personal snapshot operations](../IMV2/docs/10-operations/personal-snapshot-runbook.md).
- Direct and group public messages use the ordered room log. Send acceptance
  commits with its immutable receipt before ACK; retries return that result.
  Room cursors recover content. Personal state continues through the durable
  user-state event outbox and user projection. Neither path uses the retired
  direct fan-out selectors or delivery-plan tables.
- Room Owner / Relay uses signed Actor delivery to reach the Gateway that owns
  an authenticated device connection. Account membership coverage is distinct
  from detail-view subscriptions. Public content recovery uses durable room
  cursors; live delivery never replaces persisted history or proves local apply.
  NATS and its former room-wake configuration are retired. See the
  [Relay implementation](../docs/reviews/room-subscription-relay-implementation.zh-CN.md)
  and [account membership coverage](../docs/reviews/account-membership-incremental-audit.md).
- `IM_V2_DURABLE_RETRY_*` is an explicit exponential-backoff budget for that
  path. The initial/max delays, attempt budget and 0–100% jitter are required
  deployment inputs. Exhausted work becomes alertable `paused` durable work;
  it requires a controlled operator replay and never becomes a skipped target.
- Ordinary edits, author withdrawals and reactions append ordered room events.
  They use immutable acceptance facts and current authorization for the
  operation; room reads also enforce accepted-time and event-time visibility.
  Missing acceptance facts reject a new mutation before state changes.
  Completed operation replay remains idempotent. A room continuation can scan
  through invisible events; new edits carry complete replacement state so a
  client may cross an authorized revision gap. See the
  [mutation authority](../docs/reviews/message-mutation-delivery-authority-contract.md),
  [read contract](../docs/reviews/message-mutation-read-contract.md) and
  [replacement contract](../docs/reviews/message-edit-replacement-contract.md).
- Membership add/remove is owner-authorized and revision-fenced. Its source
  transaction records the durable operation result, room event and required
  personal-state outbox effects together; a lost response may replay the
  original operation ID without creating a second membership change.
- `IM_V2_GATEWAY_NODE_ID` must be unique per replica. It scopes the durable
  cursor that replays device-revocation events and closes local live sockets.
- `IM_V2_USER_SHARD_BUCKET`, `IM_V2_USER_SHARD_ROUTER_EPOCH` and
  `IM_V2_USER_SHARD_STORES_JSON` configure the current, static logical-bucket
  routing. Personal-state projection targets the configured current store;
  control-plane effects retain durable idempotency across databases. See the
  [static user-shard deployment scope](../IMV2/docs/10-operations/user-shard-migration-runbook.md).
  Online copy, cutover and rollback are outside the current runtime.
- `IM_V2_DIRECT_ROOM_SHARD_ID` selects the admission pool used for new
  two-user rooms. It accepts either one pool ID or a bounded comma-separated
  pool list; an unordered user-pair hash selects one stable pool so reciprocal
  opens cannot split the same conversation. Every configured pool must have a
  live lease for the selected capacity profile. Because a direct pair and its
  room profile are immutable, switching `IM_V2_CAPACITY_PROFILE_ID` also
  requires fresh test users/pairs or a newly bootstrapped environment; an
  existing pair under another profile returns retryable `UNAVAILABLE` at open
  instead of failing a later message write. `IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW` and
  `IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS` are enforced in the durable message
  transaction; the normal baseline is 3 messages per 24 hours.
- `IM_V2_GROUP_ROOM_SHARD_ID` selects the admission pool used for atomically
  created group rooms and their initial memberships.
- Content review has a durable per-message outbox and a lease-fenced worker.
  `IM_V2_CONTENT_REVIEW_MODE=disabled` stops both new job creation and worker
  startup without deleting existing jobs; messages accepted while disabled
  are not backfilled. Set the mode to `enabled` and provision
  `IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID` to run the worker. The configured
  actor is an audit principal, never a client-supplied identity and need not
  be a room member. `...VIOLATION_TERMS` and `...ESCALATION_TERMS` are only a
  deterministic baseline. Production AI/OCR/image/video adapters implement
  the same `V2ContentReviewing` boundary. A later violation is redacted using
  the existing ordered tombstone event, revokes message-media references, and
  clients erase searchable/content-bearing local fields.
- The configured 100,000-member profile requires the measured release gate in
  [`IMV2/docs/09-capacity/standard-100k.md`](../IMV2/docs/09-capacity/standard-100k.md);
  configuration alone is not capacity evidence.
- The capacity values must match the named profile assigned to rooms. A
  process-wide fallback profile is deliberately unavailable.
- The app handles `SIGTERM` by closing the listener and database container.
- Token, HMAC key, credential-replay envelope key, database URL, and frame
  payloads must never be logged.

Database integration tests require an explicitly disposable database:

```sh
IMV2_POSTGRES_TEST_DATABASE_URL='postgres://…' \
IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 \
swift test --package-path IMV2Server
```

For an isolated local PostgreSQL 16 instance (including automatic teardown),
run:

```sh
bash scripts/run_v2_postgres_integration.sh
```
