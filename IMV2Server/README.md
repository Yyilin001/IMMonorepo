# IM V2 Gateway

`IMV2ServerApp` is a standalone V2-only TLS gateway. It has no external route,
table, wire-protocol, or migration dependency.

For the cross-component data path and the distinction between implementation
and release evidence, see [the current system map](../docs/current-system-map.md)
and the [V2 document entry](../IMV2/docs/README.md).

## Provisioning

1. Create an empty PostgreSQL database and apply every numbered migration in
   [`IMV2/sql`](../IMV2/sql), in lexical order. Verify the committed migration
   set with `scripts/check_v2_sql_migration_manifest.sh` before deployment.
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
   `V2PasswordAccountRoutes` stores bcrypt verifiers only and requires an
   equal-cost dummy bcrypt digest for unknown-account timing resistance.
   The account service also requires its own Push endpoint envelope key, used
   to encrypt the opaque APNs token at rest; do not place this key in the iOS
   app or a client-visible configuration file.
5. Set every required variable in [`.env.example`](.env.example), then run the
   V2 app. The `IM_V2_NATS_*` variables are an all-or-nothing optional hint
   layer, not a required broker dependency.

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

The password fallback uses bcrypt cost 12. Generate
`IM_V2_PASSWORD_DUMMY_BCRYPT_HASH` once with the same cost so an unknown
account executes the same expensive comparison as a wrong password. Keep the
account assertion HMAC key and the device-credential replay-envelope key in
this service's secret scope only; neither belongs in the realtime gateway.
Each failed password assertion also updates the canonical-account failure
state in PostgreSQL, shared across account-service replicas. Its maximum
failures, window and lockout duration are required `IM_V2_PASSWORD_LOGIN_*`
configuration values; a lockout returns no-store `429` with `Retry-After`.
The service also applies the required
`IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_*` fixed-window budget to every account
request after validating the edge proof and exactly one edge-generated client
address. PostgreSQL stores only a HMAC digest derived using the distinct
`IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64`, never a clear-text address;
expired windows are removed in bounded batches. The production ingress must
still supply an approved trusted-proxy chain and outer DDoS/abuse controls,
and the product still needs audit, recovery and account-disable operations.

The client-side passkey flow has a complete challenge/assertion transport
boundary, but this executable does not yet mount public WebAuthn endpoints:
doing so requires an audited server verifier plus one-time challenge storage.
Password fallback is the presently deployable initial-account path.

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
The same stack is exercised on Linux CI under an isolated Compose project;
that CI evidence remains local-stack coverage, not a production deployment
approval.

## Operational notes

- `IM_V2_MAX_FRAME_BYTES`, `IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH`, in-flight requests, and inbound queued bytes are
  hard bounds; queue pressure closes the connection and clients recover by
  sync.
- `IM_V2_IDLE_TIMEOUT_MS` closes a silent TLS session. Foreground clients send
  application-owned heartbeats; background clients rely on reconnect and sync.
- `IM_V2_WORKER_BATCH_SIZE` and `IM_V2_WORKER_POLL_INTERVAL_MS` schedule the
  bounded durable path from room outbox to fan-out plan to user sync log.
- PostgreSQL durable polling is always the correctness path. When
  `IM_V2_NATS_URL` and `IM_V2_NATS_SUBJECT` are both configured, the gateway
  publishes a best-effort Core NATS wake hint only after durable publication.
  Loss, duplication or publishing failure cannot release work or change user
  state; polling recovers it. The current adapter opens a fresh connection for
  each hint and has no NATS TLS/NKey, broker acknowledgement, consumer,
  reconnection or broker-health implementation, so it is not production broker
  evidence and must not be used as a delivery dependency.
- `IM_V2_DURABLE_RETRY_*` is an explicit exponential-backoff budget for that
  path. The initial/max delays, attempt budget and 0–100% jitter are required
  deployment inputs. Exhausted work becomes alertable `paused` durable work;
  it requires a controlled operator replay and never becomes a skipped target.
- Membership add/remove is owner-authorized and revision-fenced. Its source
  transaction records the durable operation result, room event, exact frozen
  audience, fan-out plan, and room outbox together; a lost response may replay
  the original operation ID without re-evaluating later membership state.
- `IM_V2_GATEWAY_NODE_ID` must be unique per replica. It scopes the durable
  cursor that replays device-revocation events and closes local live sockets.
- `IM_V2_USER_SHARD_BUCKET` and `IM_V2_USER_SHARD_ROUTER_EPOCH` are required
  routing-control-plane inputs. The first deployment maps all users to this
  explicit logical bucket; fan-out records that bucket and epoch rather than
  deriving a destination from a user ID. The local delivery worker claims only
  this bucket. When `IM_V2_USER_SHARD_STORES_JSON` declares physical stores,
  routed fan-out projections are committed in the selected target store before
  the control delivery is completed. See
  [`user-shard migration runbook`](../IMV2/docs/10-operations/user-shard-migration-runbook.md);
  read fallback and independent-database deployment evidence remain pending.
- `IM_V2_DIRECT_ROOM_SHARD_ID` selects the admission pool used for new
  two-user rooms. `IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW` and
  `IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS` are enforced in the durable message
  transaction; the normal baseline is 3 messages per 24 hours.
- `IM_V2_GROUP_ROOM_SHARD_ID` selects the admission pool used for atomically
  created group rooms and their initial memberships.
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
