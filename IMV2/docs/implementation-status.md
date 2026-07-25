# V2 implementation status and release evidence

设计与组件关系请先看 [V2 文档入口](README.md) 和
[当前系统地图](../../docs/current-system-map.md)。本文件把“实现存在”与“可作为
发布证据”分开记录；未特别说明的本地或 CI 结果不是生产批准。

Last reviewed: 2026-07-25

This is an evidence register, not a release approval. “Implemented” means the
named code path exists and its test target compiles; it does **not** mean a
production environment or 100k workload has been proven.

The project is greenfield: no prior data, client, protocol or local-state
compatibility work is in scope under
[`ADR-000`](00-foundation/ADR-000-greenfield-cutover.md). This does not relax
V2 correctness, security, failure-recovery or release-evidence requirements.

## Latest local verification (not a production release approval)

- 2026-07-25: the V2 static migration gates now cross-check every numbered SQL
  migration against both the all-service startup schema gate and the retained
  local-volume ledger marker. A newly added migration cannot silently omit
  either check; the marker remains an explicitly reviewed immutable schema
  fact, rather than a reason to re-run historical non-idempotent SQL. This
  protects local development recovery only and is not a production migration
  runner or release approval.
- 2026-07-25: isolated PostgreSQL Server regression passed **177 tests / 49
  suites** after adding password-factor audit facts and a password-registration
  transport validation regression. Registration, rejected bcrypt verification
  and successful assertion each commit their minimal audit record atomically
  with the relevant account/rate-limit state; the record has no account handle,
  password, verifier, assertion or forwarded client IP. A malformed password
  registration remains a `400` client error instead of being misreported as a
  dependency outage. This is implementation evidence only: audit-reader
  authorization, retention, account recovery and human disable policy remain
  release blockers.
- 2026-07-25: a retained local account-stack PostgreSQL volume was migrated
  through the new `0017_public_profile_update_outbox.sql` repair migration.
  The account service and TLS gateway then passed the real HTTPS smoke path:
  invalid input, two password registrations, five rejected assertions and
  no-store lockout, device credentials, Push endpoint register/remove, TLS
  1.3 and private metrics. The aggregate audit table contained two registration
  facts and five rejection facts, without inspecting or printing identities or
  credentials. This remains local deployment evidence, not a production
  migration or security approval.
- 2026-07-25: isolated PostgreSQL Server regression passed **173 tests / 49
  suites**, including the cross-replica password-failure limiter, a
  two-database target TCP connection-refused recovery drill, and all standard
  durable-work paths.
- 2026-07-25: the 100,000-member page-bounded planning regression passed in
  **4.942 s** in the local two-CPU Docker test container. This is correctness
  evidence only; the opt-in full-drain soak and a topology-specific concurrent
  load report remain required for a 100k production claim.
- 2026-07-25: the local account/gateway smoke verification passed account
  HTTPS, password failure lockout (five `401` responses followed by no-store
  `429` with a positive `Retry-After`), device credential issuance, no-store
  Push endpoint registration and deletion, TLS 1.3, and private loopback-only
  metrics.
- 2026-07-25: a booted iPhone 17 / iOS 26.5 arm64 Simulator passed all **31**
  focused `V2ConversationStoreTests` and `V2PushWakeSettingsTests` tests, with
  zero failures or skips.

The architecture's mandatory initial decision set is tracked in
[`ADR-REGISTER.md`](ADR-REGISTER.md). A pending ADR is a release blocker for
its feature, not permission to silently select product or operational policy.

| Specification area | Current evidence | Status | Release evidence still required |
| --- | --- | --- | --- |
| TLS framing, authentication, send, idempotency | `IMV2Core`, `IMV2Server`, `IMV2ClientKit` frame/session/send modules; the uncompressed first-release protocol fail-closes on every nonzero frame flag before protobuf decoding, and each decoder applies an explicit protobuf nesting limit (gateway runtime configuration or the ClientKit first-release ceiling). The V2 trusted account/device boundary durably registers a device, issues opaque device-bound credentials, encrypts only bounded refresh-operation replay results, and revokes the device on refresh reuse under a different operation ID. Account factor results are now device-bound short-lived HMAC assertions; the Vapor device endpoint rejects an assertion used for a different device. ClientKit includes the primary AuthenticationServices Passkey adapter and no-store WebAuthn HTTP ceremony adapter; the fallback password adapter sends an explicit device ID, never persists the password, and its server route stores only worker-pool bcrypt verifiers with a same-cost dummy check. Password failures now use a PostgreSQL-persisted, canonical-handle window shared by account-service replicas; a lockout returns no-store `429` with the durable `Retry-After`, and every policy value is explicit runtime configuration. The native ClientKit generic registration adapter persists only the device ID plus pending registration UUID in a device-only Keychain item, and finalizes that UUID only after `V2AuthSession` durably writes the returned credential. Its HTTPS refresh adapter sends the durable operation ID with no-store semantics, maps only 401/403 to terminal logout, and preserves all other failures for retry. A disposable PostgreSQL + Vapor route regression models a lost registration/refresh response with an identical retry, then proves the route replays the same no-store credentials, keeps one device/session and persists exactly one operation per request ID. | Partial | Audited production WebAuthn verifier plus one-time challenge/counter storage; account-service HTTPS listener, trusted-client/IP edge limit plus factor audit/recovery/disable policy, HMAC/dummy-hash secret provisioning; real client-to-account-service network E2E evidence |
| Native ordinary chat surface | `IMApp` now composes the V2 Keychain-authenticated session, SQLite projection, TLS realtime runtime, bounded durable-command flushing, conversation list/detail and text composer. The UI talks only to injectable data-source/sender/direct-room-opening protocols. A foreground file importer copies an attachment into an App Support staging directory under a security-scoped access window; the Store uploads that copy through an injectable scan-gated uploader, and gives the durable message outbox only its opaque media reference. It never records the provider URL or a local file URL in message data, removes the staged copy only after the send intent is durably accepted or queued, and removes direct-child orphan copies from that controlled directory at the next activation. Message bubbles render opaque attachment references and, on an explicit user action, ask the authenticated edge to re-authorize/download the object before exposing the resulting local file solely through the system share sheet; the View never sees an object-provider target. Direct chat uses idempotent `openDirectRoom`; group creation records a durable operation and initial-member list before invoking `CreateGroupRoom`, then retries that same operation after reconnect. Password registration now creates a separate public `@handle` and display name atomically with the login credential. The App resolves an explicit authenticated exact handle before opening a direct room, creating a group, or adding a group member, so those product entry fields no longer take internal UUIDs. A created group emits a frozen-target, roster-free `room.created` fan-out event; a later member-add event carries the same compact identity plus its membership revision, so both initial and later members persist the title before the first message. Snapshot v11 retains those group facts and, for each active direct room only, the authoritative counterpart profile. Opening a direct room atomically appends one bounded profile projection per participant. A later display-name change atomically creates a control-plane outbox source; the gateway consumes it with a recipient work budget, checkpointing only after a page reaches each routed user shard, so retries are idempotent and forwarding migrations mirror the projection. ClientKit gives that server projection priority over its device-local explicit-lookup cache and reconstructs it on snapshot reset. The group-members sheet performs only an authenticated, seek-paginated roster query when opened, via an injectable reader; it rejects duplicate directory results before rendering. Each bounded roster entry now carries only the member's public handle and display name, which the App renders instead of `user_id`. An explicitly resolved direct identity is durably cached with its returned room on this device and supplies the direct list/detail title; unknown identities fall back to “会话”, never a UUID. Based on the loaded role, it exposes owner-only add and owner/admin non-owner removal controls; mutations are first recorded in the durable membership outbox with the displayed revision, then the roster is reloaded on acknowledgement. A sender may use the message context menu to request withdrawal of an unwithdrawn outbound message; that request is first recorded in the independent withdrawal outbox with the locally projected message revision. An acknowledgement does not optimistically tombstone the UI—the next synced projection remains authoritative. The same contextual action is available for editing a sender's unwithdrawn message: its revision-bound edit is first persisted, rejected edits leave the editor open, and the UI waits for the synced replacement text rather than overwriting its local projection. The conversation query fetches a room's complete reaction set once, aggregates it into emoji counts plus only the current user's membership bit, and renders toggles/add controls without exposing reactor IDs to the view. Reaction changes are independently durable and wait for their synced projection rather than mutating the display optimistically. On viewing a conversation, the App reports its highest visible room sequence through the independent receipt outbox. ClientKit atomically suppresses equal or older watermarks in SQLite, treating pending retries and acknowledged receipts as durable high water, so refreshes and restarts cannot create duplicate viewing operations. The privacy sheet exposes the stranger-message receive preference through the independently durable social outbox. After every availability-driven sync, the runtime replays bounded message, withdrawal, edit, reaction, receipt, social, group-creation, and membership-command queues. App tests cover projection-backed list refresh, queued message feedback, scan-gated attachment send/failure retention and staging-copy/orphan cleanup, re-authorized media download success/failure and opaque cache naming, revision-bound withdrawal/edit, reaction add/remove selection, visible-sequence receipt reporting, handle-based direct/group/member-add actions, roster pagination and revision-bound membership changes, and privacy-setting state. A booted iPhone 17 / iOS 26.5 arm64 Simulator passed all 31 focused conversation-store and Push-wake tests with no failures or skips. | Partial | direct-profile backlog/capacity thresholds、真实多设备 live-sync 与离线 cursor 回归；群名单保持按需读取，不做资料 fan-out |
| Durable room event, outbox, fan-out, user sync | numbered `IMV2/sql` migrations and PostgreSQL stores; a disposable-PostgreSQL regression abandons both outbox and delivery leases, then proves replacement workers recover them after lease expiry and complete all three durable sync projections. The planner commits each immutable enumeration page, its deliveries and its checkpoint in one transaction; an injected interruption after the first page resumes strictly after that checkpoint, while delivery claims are held until the plan is complete. The final completion-unit release transaction closes the source outbox only after every unit is terminal; the same regression proves it remains nonterminal after an earlier unit completes. Worker failures use deterministic bounded exponential backoff whose initial/max delay, budget and jitter are required deployment inputs; a retry-budget exhaustion changes the durable row to `paused` rather than terminal/skipped. `IMV2OperatorServerApp` is a separate loopback-only, dedicated-secret control plane: its authenticated one-row replay writes durable audit evidence atomically, supports idempotent operation IDs, and only returns paused work to `pending`; its runbook prohibits batch/terminal replay. The checked-in GitHub workflow runs the disposable PostgreSQL Server suite; checked-in Prometheus rules make metrics loss and any paused row page `im-v2-platform-oncall`. | Partial | Actual Alertmanager receiver approval, capacity-derived backlog thresholds, and operator-access (bastion/mTLS) deployment evidence |
| Membership and authorization intervals | membership service/store and fan-out target rules; owner-only member add and owner/admin removal of non-owner members are enforced in the same transactional, frozen-audience path. A separate authenticated V2 `ListRoomMembers` seek-paginated directory reads current active membership from PostgreSQL (maximum 100 entries/page) and returns the authenticated actor's current role on every page, so a management UI never needs to enumerate a large roster to decide which controls to show. Roster data is never copied into fan-out or sync events. | Implemented | revoked-history and migration integration evidence |
| Withdrawal, reaction, edit | Core commands, PostgreSQL stores, gateway, sync projection and local outboxes. A multi-connection PostgreSQL regression races edit against withdrawal at the same expected revision: exactly one mutation commits, while the other deterministically reports revision conflict or terminal tombstone; only one operation/event/fan-out plan is added beyond message acceptance. | Implemented | CI PostgreSQL mutation suite |
| Read receipt | independent Core/store/gateway/transport/outbox implementation. The PostgreSQL regression proves receipts are monotonic user state and produce no fan-out work; native ClientKit persists a retryable receipt across restart and rejects stale or unpersistable unsigned sequence values rather than advancing its local result or trapping in SQLite conversion. | Implemented | CI publication; real device/backend transport record |
| Push wake hints | durable wake outbox, campaign/budget admission primitive and APNs adapter. PostgreSQL records the one-time device-budget admission separately from the provider lease: a provider failure or expired worker lease can be retried/reclaimed without double-spending the device-key budget; a disabled campaign or missing/exhausted budget suppresses only that wake. An authenticated device registers only an opaque APNs token, encrypted with a separate deployment envelope key and bound to a fresh endpoint generation. The native ClientKit HTTPS adapter uses a refresh-fenced bearer/device pair, explicit no-store headers and an injected transport to register/delete an endpoint; it neither persists nor returns the token. The iOS app exposes an explicit background-wake setting (off by default), registers with UIKit only after that choice, forwards the in-memory APNs token to the authenticated adapter, retries deletion after a failed opt-out, and maps a contentless wake back to the existing authenticated sync path. Its build settings distinguish development/production APNs environments, its entitlement requests APNs capability, and a Release configuration gate rejects a non-production Push environment. The APNs worker sends only the generic `content-available` wake payload; it never places room, sender, message, media or token data in the notification. Invalid/unregistered APNs responses fence-disable only the matching endpoint generation and terminally suppress that wake, while transient provider failures release the durable lease for retry. The provider stays disabled unless explicit APNs credentials and the envelope key are supplied at gateway startup. | Partial | Approved eligibility (foreground, muted, user-setting) and campaign policy; campaign planner; Push-enabled App ID/provisioning profile plus real APNs credential/end-to-end evidence and production failure drill |
| Relationships and stranger direct messaging | direct-room creation, recipient setting and transactional stranger admission; a multi-connection PostgreSQL regression proves four concurrent first stranger messages consume at most the configured three-message window (three commits, one limit rejection). Relationship request/accept/reject/remove and private block/unblock commands; durable user-sync records, PostgreSQL integration, ClientKit wire adapter, local projections and durable offline outbox. The complete PostgreSQL snapshot materializer uses one repeatable-read watermark: relationships, the requesting user's blocks and stranger-message preference come from authority, while timeline visibility comes only from that user's delivered sync log. A server-owned stager creates the existing device/generation reset fence; clients never submit snapshot bytes or watermarks. | Partial | CI runtime record |
| Media references and scanning | Core has opaque media IDs, durable upload intents, scan-state transitions, attachment-only message references and snapshot schema v5; PostgreSQL atomically verifies owner + `available` scan state, persists message references and event payloads; the V2 gateway/client protocol and durable client outbox carry only opaque media IDs (never object URLs). Upload authorization is now bound to the authenticated device in a durable grant: a separate fenced exchange verifies the still-active device and `pending_upload` state, accepts only a one-time exact-byte HTTPS provider target in memory, releases a failed provider claim for bounded retry, and requires that consumed grant before the same device can submit completion. Completion creates the bounded scanner outbox item; scanner-provider failure only releases that item, while success atomically marks the object `available` or `failed`. The authenticated upload edge exposes no-store target, completion, and lifecycle-status contracts; ClientKit uses one coherent bearer/device credential pair, uploads exact bytes, then waits for `available` before returning control to a message sender. The App's foreground attachment path stages an importer copy locally and admits its opaque reference to the message outbox only after that wait succeeds; failed scans/uploads retain the draft and local copy for an explicit retry. The App's explicit download path re-authorizes through ClientKit on every request, writes through a random temporary cache file, then atomically replaces an opaque SHA-256-named App Support cache entry; the managed directory and each file are backup-excluded and use foreground-only file protection, and only interrupted temporary files are cleaned at activation. The authenticated media service issues a short-lived opaque per-device download session only after rechecking the active device, current room membership, unwithdrawn message, and the user's actually delivered `message.accepted` projection. A fenced provider-session service atomically claims one session, repeats that authorization at exchange time, and can return a single provider target only in memory; failed provider issuance releases the session while successful issuance consumes it. A framework-neutral `GET /v2/media/{mediaID}` handler contract validates the path ID and emits a short-lived HTTPS-only JSON target envelope. Its Vapor adapter reuses device-bound bearer authentication, maps unauthorized/unavailable media to opaque responses, and emits no-store JSON; native ClientKit resolves it locally with a coherent bearer-token/device pair, no-store semantics, no automatic retry, explicit HTTP errors, and then directly transfers object bytes with URLSession. The runtime schedules the bounded PostgreSQL retention worker using an explicit withdrawn-reference interval and a separately configured low-frequency maintenance cadence; it uses `SKIP LOCKED` to terminally expire eligible objects and emit a privacy-safe provider cleanup outbox record. A separate fenced worker retries only provider byte deletion. | Partial | Concrete provider and scanner adapters/configuration, production listener composition/auth rate limits, approved background-transfer/relaunch policy, retention and abuse-load tests |
| Mentions | Frozen server visibility authorization (owner/admin-only `@all`, non-enumerating user-target rejection), immutable command/idempotency fields, PostgreSQL `message_mentions` rows, gateway protobuf fields, and ClientKit outbox + incremental/snapshot message projections (schema v6). The full snapshot materializer replays the immutable mention set embedded in each user-delivered message-acceptance event, so later membership changes cannot expand history visibility. | Partial | suppression-aware private notification/push, production PostgreSQL integration/capacity evidence |
| Moderation | ADR-001 standard-chat policy; tested Core/service contracts; PostgreSQL owner/admin explicit message-redaction transaction with privacy-safe audit retention, canonical tombstone, fan-out/outbox and idempotent replay; generated V2 protobuf and authenticated gateway command; native client inbound tombstone projection and durable redaction outbox. The local sync dispatcher treats `message.redacted` as the same terminal tombstone shape as author withdrawal before advancing its cursor. Room-freeze and active-mute state are authoritative send-admission checks. Owner/admin mute is a distinct PostgreSQL transaction with durable operation/audit/event/fan-out/outbox and idempotent replay; generated protobuf, authenticated gateway routing and native client transport are implemented; incremental client sync persists its privacy-safe moderation projection before ACK. The native client also durably queues mute commands, retries with the same operation ID after restart, normalizes wire-millisecond deadlines, and terminally rejects expired commands. Snapshot schema v11 carries privacy-safe mute, room-control, delivered group-room identity/revision, and active direct-room counterpart-profile facts; the server materializer replays delivered history and rebuilds only bounded direct state from authority. Server validation forbids duplicate source events or room positions across snapshot pages. A separate, server-to-server trusted-safety service controls room freeze/unfreeze without accepting a gateway actor; each control transition atomically persists state, audit, event, fan-out, outbox and idempotent result. Freeze/unfreeze facts fan out as moderation records and update the native client's durable current room-control projection. Audit-level member removal is a separate protobuf command, moderation operation/audit row and native durable outbox: one transaction changes membership, freezes the pre-removal audience (including the departing user), records a canonical `membership_changed` event, and returns the persisted membership revision on replay. The runtime schedules a bounded PostgreSQL audit-retention worker using `SKIP LOCKED`, deleting only expired audit copies while preserving operation/idempotency records. | Partial | notification/appeal presentation; operational recovery evidence |
| Shard routing/move | a PostgreSQL logical router seeds one explicit default bucket/epoch only when absent, then reads durable per-user write-owner overrides plus optional read-fallback metadata for every planner/delivery batch. Its transactional control-plane cutover is epoch-CAS, operation-ID idempotent and records the operator principal. A worker resolves every claimed target again and, when the route is stale, fence-handoffs that same pending delivery to the current logical write bucket rather than writing old-owner state, duplicating the target, or terminal-skipping it. PostgreSQL integration covers default routing, idempotent/stale cutover rejection, old-to-new bucket handoff with one durable row. `user_shard_migrations` reserves one migration per user; its row-locked PostgreSQL store fences every phase and stores only bounded error categories plus equal fingerprints. The durable coordinator never holds a database transaction across adapter I/O and leaves interrupted attempts observable for retry. A concrete PostgreSQL projection adapter copies receiver inbox, sync log/sequence, device cursor, snapshots/pages and capabilities between independently addressed source/target stores; it pages sync history, verifies canonical SHA-256 fingerprints and supplies an idempotent source cleaner. Gateway and loopback-only operator startup parse a deployment-only physical-bucket registry, verify every declared schema before traffic, and never expose those addresses through records/logs/API bodies. Fan-out writes into the routed target before control completion; during forwarding, direct/social authority writes mirror their already-committed source sync record (including its sequence) to the target and response-loss retry is idempotent. After cutover, direct/social projections allocate their next sequence in the current write owner, so a stale control-store counter cannot collide with target fan-out state. The runtime resolves every sync pull/ack/snapshot operation to the current write owner, never an automatic read fallback. It schedules one bounded delivery pass for every configured logical bucket while preserving a process-wide concurrency cap, and durable-work metrics aggregate all configured delivery buckets. Initial copy/verify reaches `forwarding`; a separate final fingerprint check reaches `verified`, which gates cutover. Two-PostgreSQL-container regressions cover target-commit/control-completion recovery, a TCP-refused target outage with durable retry and exact recovery, direct/social forwarding, post-cutover direct/social allocation after a target fan-out record, and multi-bucket pipeline scheduling. The operator exposes authenticated single-user `copy-verify`, `verify-forwarding`, cutover and retention-window rollback endpoints only. Rollback accepts no bucket, derives source/target from the durable migration, uses a fresh epoch-CAS, is operation-ID idempotent and marks the migration `rolled_back` so cleanup cannot delete the restored source owner. A route cutover still records the default 24-hour rollback retention deadline; the runtime schedules leased post-deadline source cleanup. | Partial | Operator-access deployment evidence and capacity evidence |
| Redis/NATS adapters | Redis is not a V2 correctness dependency. PostgreSQL durable polling is the default. An optional Core NATS publisher is wired when `IM_V2_NATS_URL` and `IM_V2_NATS_SUBJECT` are both present; it publishes only a `(sourceEventID, planID)` wake hint **after** the durable PostgreSQL publisher completes. The wrapper suppresses hint failure, so loss or duplication cannot release work or change a user projection. Configuration rejects a partial endpoint/subject pair. The current minimal adapter creates a fresh connection per hint and writes Core NATS `CONNECT`/`PUB`; it has no consumer, connection reuse/reconnect, NATS TLS/NKey, broker ACK, broker health metric, or real-broker success-path test. A focused Docker regression proves that an injected hint failure leaves durable outbox work publishable; it does not prove broker delivery. | Partial | real-broker publish/consume and loss/recovery integration tests; authenticated/TLS deployment policy; consumer wake integration; metrics/alerts and capacity/failure evidence |
| Observability, deployment, PITR/DR | privacy-safe gateway/fan-out telemetry boundary, structured-log adapter, and deterministic Prometheus exporter. The runtime fans the same closed event vocabulary to logs and metrics, but suppresses all-zero fan-out poll events so the configured 100ms durable-work loop cannot create idle log/metric noise; claim, retry/release, progress and failure facts remain emitted. It exposes only `/metrics` on an explicitly configured loopback listener (`127.0.0.1`/`::1`), never the public realtime/media surfaces; it drops trace IDs and clamps invalid negative counts. Each scrape also reads a process-local connection-registry snapshot and exposes only active authenticated device/connection gauges; a separate gateway transport snapshot adds all-socket count, inbound queue peak, declared-frame-limit violations, and closed connection reasons from a finite vocabulary—never identifiers or labels. The same private scrape reads aggregate PostgreSQL durable-work state: ready/leased/scheduled/**paused** room-outbox rows, ready/leased direct-profile propagation sources, nonterminal fan-out plans, ready/leased/scheduled/**paused** deliveries for the configured logical bucket, per-ready-device sync backlog, reset-pending device count, and ready/leased/suppressed Push-wake rows. A separate availability gauge is zero if that database read fails; no bucket, identifier, token, or error text becomes a label. The CI logical-restore drill rebuilds `im_v2` from a custom dump and verifies migration-owned retry/audit facts; it is explicitly not a PITR/RPO/RTO claim. Optional NATS hints have no broker-level telemetry yet. See `docs/10-operations/observability.md`. | Partial | NATS hint/shard/capacity metrics, deployed Alertmanager/runbooks, WAL/PITR restore/failover exercises |
| 100k capacity | `docs/09-capacity/standard-100k.md` defines the release gate; the disposable PostgreSQL suite verifies a single 100,000-member fan-out plan pages at 1,000 recipients and writes exact, deduplicated durable accounting. An explicit opt-in isolated regression drained all 100,000 deliveries through the real per-target transaction path, proving one user-sync and consumer-inbox record per recipient, 100 released completion units, terminal plan state, and room/shard reservation release (2026-07-24: 170.6 s on the local two-CPU Docker test container). A separate opt-in recovery soak injects worker loss before the first target checkpoint, after the first target checkpoint, before the final terminal/release update, and after that update for each of those 100 units; after the durable per-page planner checkpoint change, lease-expiry replacements again reached exact terminal/release accounting with no post-release claimable work in 172.255 s on that container (2026-07-24). Runtime fan-out invokes independently bounded planner and delivery worker groups, with aggregate telemetry and PostgreSQL claims fencing cross-replica work. | Unproven | concurrent executable workload, dated topology/results, approved thresholds and failure test report |

## Verification environment

The Core and Server regression runs in an isolated Colima/Docker Compose
environment, with disposable PostgreSQL, through
`docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm --build swift-tests`
(the container entrypoint is `scripts/run_v2_isolated_tests.sh`). On 2026-07-24 the current isolated run
passed 42 Core tests and 136 Server tests, including the
PostgreSQL integration suite. After the optional NATS-hint change on 2026-07-25,
`swift build --build-tests --package-path IMV2Server` and the isolated focused
`V2OutboxRelayTests` run passed (5 tests, including the injected broker-hint-loss
case) together with the SQL migration-manifest check. The complete isolated
Core/Server suite must be rerun before the earlier full-suite count is treated
as evidence for that NATS change. The client is intentionally native:
`swift build --build-tests --package-path IMV2ClientKit` succeeds on this Mac.
Native ClientKit tests run successfully when each invocation uses a disposable
SwiftPM scratch directory via
`scripts/run_v2_clientkit_native_tests.sh`; this avoids stale shared-build
signing/load state while preserving the real macOS runtime. The script defaults
to four compiler jobs so the local run does not monopolize the Mac. On
2026-07-25, the complete native ClientKit suite passed 115 tests in 26 suites,
including the receipt high-water restart regression and media authorization
transfer tests. Its backup-policy test writes only a uniquely named Application
Support child and removes it afterward. The Linux workflow
`.github/workflows/imv2-tests.yml` remains the authoritative CI execution path
for ClientKit unit tests and disposable-PostgreSQL integration tests; it does
not change the client runtime deployment model.

On 2026-07-25, the IMApp Debug simulator baseline was repaired by declaring
`IMV2Core` as a direct local package product of both IMApp and IMAppTests. The
V2-only App surface imports Core types directly, so relying on ClientKit's
transitive package dependency left the app/test link steps without the Core
framework. Under Xcode 26.6, a generic iOS Simulator `build-for-testing` now
passes for both arm64 and x86_64, compiling the V2 conversation surface,
`IMAppTests`, and `IMAppUITests`. A booted iPhone 17 / iOS 26.5 arm64 simulator
also passed all 31 focused `V2ConversationStoreTests` and
`V2PushWakeSettingsTests` cases.
That run additionally fixed the media-cache cleanup regression: interrupted
hidden `.partial` files are now enumerated and removed, while complete cache
files remain untouched. The macOS CI configuration first performs the generic
Simulator `build-for-testing`, then dynamically selects and boots an available
iPhone simulator to run both `V2ConversationStoreTests` and
`V2PushWakeSettingsTests` with `test-without-building`. The clean-environment
record is [IMApp Production Config Gate #30150647120](https://github.com/Yyilin001/IMMonorepo/actions/runs/30150647120), which passed at commit `c02af08` on 2026-07-25.

On 2026-07-25, this baseline was re-verified locally at `12a1948`: `xcodebuild
build-for-testing -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration
Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
successfully built the App, unit-test and UI-test bundles.  The corresponding
`test-without-building` run on the booted iPhone 17 / iOS 26.5 arm64 simulator
also passed every selected `V2ConversationStoreTests` and
`V2PushWakeSettingsTests` case.  This is a local simulator regression record,
not a substitute for a signed-device or production-network E2E result.

At `d0fcae9`, the previously empty `IMAppUITests` target gained a deterministic
fresh-launch check.  It passes `-v2-ui-testing-signed-out` only as a process
argument, so the production route still performs its normal Keychain-backed
restore while the UI test does not depend on historical simulator credentials
or a live account service.  The iPhone 17 / iOS 26.5 arm64 run passed the
password-sign-in control assertions, and the macOS gate now includes that UI
test alongside the focused unit suites.

The same baseline audit found that the old macOS workflow called removed
`Makefile` targets and that the Release build phase directly executed a
non-executable validation script. The workflow now invokes the checked-in
scripts with `bash`, and the build phase also uses an explicit shell. Because
this gate validates build settings, it deliberately declares no output: Xcode
therefore reruns it when Release configuration changes in an incremental
derived-data build. A local production-valued Release build passed after
reading its processed Info.plist; changing its account URL to HTTP failed the
build with `production_v2_account_requires_https`. The Linux V2 workflow now
uses Swift 6.2, satisfying ClientKit's Swift-tools 6.2 manifest; the local
account/gateway image independently builds with Swift 6.3. At commit `c02af08`,
[IM V2 Tests #30150647156](https://github.com/Yyilin001/IMMonorepo/actions/runs/30150647156)
passed Core, ClientKit, Server/PostgreSQL, migration ledger, logical restore,
protobuf/SQL/Prometheus/environment contracts, plus a cold local account-stack
start and smoke run. These CI records prove reproducibility only; they are not
production deployment, WebAuthn, capacity, or disaster-recovery evidence.

On 2026-07-25, `scripts/check_v2_runtime_env_examples.sh` was added to the V2
CI path. It checks declarations only—never real secret values—across the
gateway, loopback-only account service and loopback-only operator examples.
In particular, the account example now declares the required Push endpoint
envelope key, preventing a documented configuration from failing before the
service binds its listener. This is a deployment-configuration contract, not
evidence of a production secret manager, public ingress, rollback or
disaster-recovery deployment.

The local account stack is separate from those test runners: on 2026-07-25,
`IMV2/scripts/run_v2_local_account_stack.sh` completed only after PostgreSQL,
the loopback account issuer, Caddy HTTPS edge, and the V2 TLS gateway became
healthy. Its companion `verify_v2_local_account_stack.sh` then verified an
HTTPS invalid-input rejection, password registration to device-credential
issuance hand-off, five rejected password assertions followed by a no-store
`429` with a positive `Retry-After`, authenticated Push endpoint
register/remove with `204` and `no-store` (without printing either token), a
local-CA-verified TLS 1.3 gateway handshake, and the gateway container's
private metrics endpoint. The latter asserts HTTP 200,
`no-store`, no host-published metrics port, the complete durable-work
ready/leased/scheduled/paused metric vocabulary, and Push-wake
ready/leased/suppressed metrics; it therefore catches a stale
gateway image that otherwise passes only the TLS health check. No assertion or
credential is printed. This is local integration evidence only; it is not
production WebAuthn, Alertmanager routing, rate-limit, capacity, or release
evidence.

The V2 GitHub workflow now also starts that stack in its own Linux Compose
project and runs the same smoke script, followed by volume removal. A remote
result is still required before it can be counted as CI evidence; the job
proves the checked-in startup and verification path can be exercised without
developer credentials or an existing local stack.

Before starting account/gateway, the local stack refreshes PostgreSQL's
read-only SQL bind mount by recreating only the container (the named data
volume is retained), then records numbered SQL migrations in a local-only
`im_v2.local_schema_migrations` ledger. A retained development volume is
bootstrapped from immutable schema markers and receives only missing
incremental SQL; historical non-idempotent migrations are never blindly
re-run and no local data is dropped. This convenience helper is not a
production migration runner. Its disposable regression bootstraps a fresh
volume, removes the `0010` user-shard router control table/ledger row, and
proves that only `0010` is reapplied before a no-op repeat run. The GitHub V2
workflow runs that disposable regression with a generated one-time local
environment file; it never consumes or writes a developer's real
`.env.local`.

The opt-in isolated 100k delivery-drain regression described in
`docs/09-capacity/standard-100k.md` passed on 2026-07-24 in 170.6 seconds. Its
separate 100k lease-expiry recovery soak passed in 172.255 seconds after the
durable per-page planner checkpoint change, simulating all four
checkpoint/terminal-update interruption boundaries for every completion unit.
Both are deliberately excluded from the default suite and the isolated runner
rejects a requested Server-test filter that matches zero tests, so either
command cannot report a false green focused run. They verify durable correctness
at that scale only; no throughput/SLO claim follows from them.

The executable-contract gate also regenerates V2 protobuf bindings in a
temporary directory and checks them against committed sources, then regenerates
`IMV2/sql/migration-manifest.sha256` from the numbered SQL migrations and checks
that manifest. Both checks run in the GitHub workflow; the SQL manifest check
also runs in the isolated Core/Server regression. The native ClientKit run
remains local to macOS.

## Completion rule

The V2 refactor is not complete until every “Missing” and “Partial” row is
implemented or explicitly removed from the approved specification, every
decision-pending ADR is approved, and the stated CI/integration/capacity/DR
evidence exists. In particular, a 100k group is not a release claim without a
dated successful load report.
