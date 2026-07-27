# V2 implementation status and release evidence

设计与组件关系请先看 [V2 文档入口](README.md) 和
[当前系统地图](../../docs/current-system-map.md)。本文件把“实现存在”与“可作为
发布证据”分开记录；未特别说明的本机自动化验证结果不是生产批准。

Last reviewed: 2026-07-27

This is an evidence register, not a release approval. “Implemented” means the
named code path exists and its test target compiles; it does **not** mean a
production environment or 100k workload has been proven.

The project is greenfield: no prior data, client, protocol or local-state
compatibility work is in scope under
[`ADR-000`](00-foundation/ADR-000-greenfield-cutover.md). This does not relax
V2 correctness, security, failure-recovery or release-evidence requirements.

## Latest local verification (not a production release approval)

- 2026-07-27: terminal client-command rows now have an explicit local
  lifecycle: after a successful durable synchronization, rows that have
  reached any terminal state are retained for 24 hours for short-term
  diagnostics and then purged; pending retry records are never eligible. All
  eleven command tables have matching partial expiry indexes, and regression
  coverage verifies both the schema and that an old terminal message is
  removed while an old pending message remains durable. This limits local
  accumulation of rejected edit text, group titles, identifiers, and reason
  codes without changing server-side audit retention. The native
  `IMV2ClientKit` suite passed **137 tests**; the selected iPhone 17 / iOS
  26.2 Simulator passed the full shared `IMApp` scheme with **80 Swift tests**
  and **2 UI tests**, zero failures. This is local-storage evidence only, not
  capacity or deployment evidence.
- 2026-07-27: the SQLite migration now creates partial semantic-intent
  indexes for every durable command path that reuses an equivalent pending
  operation. The lookup stays scoped to the small pending subset, and an
  index-schema regression verifies all nine indexes exist after migration.
  The native `IMV2ClientKit` suite passed
  **134 tests**; the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **80 Swift tests** and **2 UI tests**, zero
  failures. This is local durable-storage evidence only, not capacity or
  deployment evidence.
- 2026-07-27: `IMApp/Scripts/verify_local_account_registration_e2e.sh`
  passed against the selected booted iPhone 17 / iOS 26.2 Simulator and the
  isolated local account stack. Its three UI integration tests exercised the
  local HTTPS edge, password registration, device-credential issuance,
  Keychain-backed session commit, relaunch, and disposable test-scope cleanup.
  The command uses only local Docker services and the selected simulator; it
  does not establish two-device synchronization, physical-device, or
  deployment evidence.
- 2026-07-27: equivalent pending member-mute and audit-level member-removal
  commands now atomically reuse their original operation ID across retries
  and restarts. A mute still requires the same target, canonical expiry, and
  reason; an audit removal still requires the same target and reason, so a
  changed moderation decision remains distinct. The native `IMV2ClientKit`
  suite passed **133 tests**; the selected iPhone 17 / iOS 26.2 Simulator
  passed the full shared `IMApp` scheme with **80 Swift tests** and **2 UI
  tests**, zero failures. This is local durable-intent evidence only, not
  multi-device or deployment evidence.
- 2026-07-27: equivalent pending message edits and message reactions now
  atomically reuse their original operation ID across retries and restarts.
  An edit still requires the same revision and replacement text, while a
  reaction still requires the same emoji and action; changed text and an
  add-to-remove transition remain distinct user intents. The native
  `IMV2ClientKit` suite passed **131 tests**; the selected iPhone 17 / iOS
  26.2 Simulator passed the full shared `IMApp` scheme with **80 Swift
  tests** and **2 UI tests**, zero failures. This is local durable-intent
  evidence only, not multi-device or deployment evidence.
- 2026-07-27: a duplicate pending moderator message-redaction command now
  atomically reuses the original operation ID when its room, message, and
  bounded reason code are unchanged. This keeps one audit action across a
  lost response or app restart; a changed reason remains a distinct action.
  The native `IMV2ClientKit` suite passed **129 tests**; the selected iPhone
  17 / iOS 26.2 Simulator passed the full shared `IMApp` scheme with **80
  Swift tests** and **2 UI tests**, zero failures. This is local
  durable-intent evidence only, not multi-device or deployment evidence.
- 2026-07-27: a duplicate pending message withdrawal now atomically reuses
  the original operation ID when its room, message, and expected message
  revision are unchanged. A retry after a lost response or app restart no
  longer writes a second terminal command; a changed revision stays a distinct
  user action. The native `IMV2ClientKit` suite passed **128 tests**; the
  selected iPhone 17 / iOS 26.2 Simulator passed the full shared `IMApp`
  scheme with **80 Swift tests** and **2 UI tests**, zero failures. This is
  local durable-intent evidence only, not multi-device or deployment evidence.
- 2026-07-27: equivalent pending social commands now atomically reuse their
  operation ID across restarts. This covers relationship, user-block, and
  stranger-message-preference commands; a changed target or desired preference
  remains a later, distinct durable command. The native IMV2ClientKit suite
  passed **127 tests**; the selected iPhone 17 / iOS 26.2 Simulator passed
  the full shared IMApp scheme with **80 Swift tests** and **2 UI tests**,
  zero failures. This is local durable-intent evidence only, not multi-device
  or deployment evidence.
- 2026-07-27: durable group-membership changes now atomically reuse an
  equivalent pending room, target, action, and expected-roster-revision
  intent. A retry after a lost response or restart continues with the original
  operation ID; a changed revision or terminal command remains a distinct
  user action. The native `IMV2ClientKit` suite passed **126 tests**; the
  selected iPhone 17 / iOS 26.2 Simulator passed the full shared `IMApp`
  scheme with **80 Swift tests** and **2 UI tests**, zero failures. This is
  local durable-intent evidence only, not multi-device or deployment
  evidence.
- 2026-07-27: durable group creation now atomically reuses an equivalent
  pending title-and-initial-members intent in the local SQLite store. A lost
  response, sheet retry, or app restart therefore continues with the original
  operation ID instead of recording a duplicate group-creation command. The
  native `IMV2ClientKit` suite passed **125 tests**; the selected iPhone 17 /
  iOS 26.2 Simulator passed the full shared `IMApp` scheme with **80 Swift
  tests** and **2 UI tests**, zero failures. This is local durable-intent
  evidence only, not multi-device or deployment evidence.
- 2026-07-27: direct-room opening and group creation now each have a Store
  single-flight gate, with matching disabled form controls and task ownership
  in the list UI. A second tap cannot resolve another identity or enqueue a
  second group-creation operation while the first request is suspended. Two
  suspended-boundary regressions cover the direct and group paths. The
  selected iPhone 17 / iOS 26.2 Simulator passed the full shared `IMApp`
  scheme with **80 Swift tests** and **2 UI tests**, zero failures. This is
  local command-intent evidence only, not multi-device or deployment
  evidence.
- 2026-07-27: group membership changes now remain mutually exclusive with
  in-flight moderated removals. The owner-only add controls expose the same
  disabled state as member-row controls, and the store independently rejects
  a concurrent membership command so it cannot be recorded against a roster
  revision that a moderation removal is about to advance. The page also keeps
  its membership and moderation tasks single-flight while visible, rather
  than cancelling an already-started durable command when the user taps
  again. A suspended-removal regression proves no membership command reaches
  its durable boundary during that window. The selected iPhone 17 / iOS 26.2
  Simulator passed the full shared `IMApp` scheme with **78 Swift tests** and **2 UI tests**, zero
  failures. This is local concurrency evidence only, not multi-device or
  deployment evidence.
- 2026-07-27: disabling background-sync wake now persists a token-free
  pending-removal marker before issuing the device-scoped, idempotent endpoint
  DELETE. If that DELETE fails, the next restored local session retries it and
  clears the marker only after success; a disabled preference therefore cannot
  silently abandon an old remote endpoint. The focused Push-wake suite covers
  the failed-delete/relaunch recovery. The selected iPhone 17 / iOS 26.2
  Simulator passed the full shared `IMApp` scheme with **77 Swift tests** and
  **2 UI tests**, zero failures. This is local endpoint-state evidence only,
  not APNs delivery or deployment evidence.
- 2026-07-27: sign-out is now single-flight across required Push-endpoint
  removal and credential deletion. Repeated taps and a simultaneous
  terminal-auth callback cannot interleave those steps or cancel an already
  started sign-out. A focused regression proves the gate rejects duplicate
  work and admits a later attempt after completion. The selected iPhone 17 /
  iOS 26.2 Simulator passed the full shared `IMApp` scheme with **76 Swift
  tests** and **2 UI tests**, zero failures. This is local sign-out-state
  evidence only, not APNs delivery or deployment evidence.
- 2026-07-27: sign-out now treats device Push-endpoint removal as a required
  precondition to deleting the current credential. A transient endpoint DELETE
  failure remains in the persisted pending-sign-out state; retry and next
  launch repeat the idempotent DELETE with the still-protected credential,
  then delete that credential only after removal succeeds. The app never
  persists the endpoint token. The Push-wake suite includes a terminal
  removal-failure regression. The selected iPhone 17 / iOS 26.2 Simulator
  passed the full shared `IMApp` scheme with **75 Swift tests** and **2 UI
  tests**, zero failures; the dedicated local-account UI suite also passed
  **3 tests**. This is local sign-out-state evidence only, not APNs delivery
  or deployment evidence.
- 2026-07-27: a contentless push that wakes the app while it remains in the
  background now owns only its bounded realtime catch-up. After sync it stops
  the runtime and its long-lived availability/heartbeat loops; if the scene
  becomes active during the catch-up, foreground lifecycle ownership keeps
  that shared runtime running. A focused ownership regression covers both
  outcomes. The selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **74 Swift tests** and **2 UI tests**, zero
  failures. This is local lifecycle evidence only, not APNs delivery or
  deployment evidence.
- 2026-07-27: live availability-driven synchronization now completes a
  `resetRequired` snapshot before it notifies projection observers or replays
  durable commands. Previously only the initial connection path materialized
  a reset, so a reset arriving on an established realtime connection could
  leave the local cursor fenced at `resetPending`. The new regression injects
  that ordering and proves the snapshot is acknowledged, the cursor returns
  to `ready`, and post-sync work runs exactly once. The complete native
  `IMV2ClientKit` suite passed **124 tests in 26 suites**, and the selected
  iPhone 17 / iOS 26.2 Simulator again passed the shared `IMApp` scheme with
  **73 Swift tests** and **2 UI tests**, zero failures. This is local
  synchronization-state evidence only, not multi-device or deployment
  evidence.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **73 Swift tests** and **2 UI tests**, zero
  failures; the dedicated local-account UI suite also passed **3 tests**.
  Each completed initial or availability-driven durable synchronization now
  emits an opaque, generation-only projection-change signal before command
  replay. The conversation list and an open conversation subscribe to that
  signal and re-read their local SQLite projection, so incoming synchronized
  content becomes visible without polling, UI-owned network requests, or
  exposing sync payloads to SwiftUI. ClientKit's **123 tests in 26 suites**
  prove the signal follows both initial and live synchronization; a suspended
  detail-projection regression proves an already-open conversation reflects
  the newly persisted message. This is local client correctness evidence
  only, not remote delivery, multi-device or deployment evidence.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **72 Swift tests** and **2 UI tests**, zero
  failures. Message withdrawal, edit and reaction now share a per-message
  single-flight gate, so repeated taps cannot enqueue conflicting commands
  against one projection revision; the affected controls expose a saving
  value while the gate is held. A suspended-withdrawer regression proves the
  same message accepts only one mutation while retaining independent actions
  for other messages. This is local client correctness evidence only, not a
  remote-delivery or deployment guarantee.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **71 Swift tests** and **2 UI tests**, zero
  failures. Push-wake preferences and endpoint registrations now have
  generation fences: a cancelled late endpoint removal cannot overwrite a
  newer enable, and a late APNs registration result cannot resurrect a later
  disable. Focused suspended-endpoint tests prove both orderings. This is
  local client state evidence only, not APNs delivery or deployment evidence.
- 2026-07-27: after adding cancellation fences to session restoration,
  password/passkey session establishment, foreground realtime startup and
  direct-room identity caching, the selected iPhone 17 / iOS 26.2 Simulator
  again passed the full shared `IMApp` scheme with **69 Swift tests** and
  **2 UI tests**, zero failures. The dedicated local-account UI suite also
  passed **3 tests** through real local HTTPS registration, device-credential
  issuance, Keychain session creation and scoped cleanup. An authentication
  generation gate, with a focused regression, now prevents a cancelled or
  superseded attempt from applying stale signed-out or signed-in state over a
  newer login route. This is local
  simulator lifecycle evidence only, not a signed-device or deployment
  guarantee.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **68 Swift tests** and **2 UI tests**, zero
  failures. The conversation UI now also fences cancellation after every
  remote command, attachment-stage/upload/download, or room-opening response
  and before it updates drafts, feedback, navigation results, attachment
  state, or member state. Focused non-cooperative fakes prove cancellation
  preserves a draft, suppresses a late direct-room navigation result, and
  prevents a late member mutation from triggering a refresh. This is local
  client lifecycle evidence only, not a remote-delivery or deployment
  guarantee.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **65 Swift tests** and **2 UI tests**, zero
  failures. Privacy preferences, public-identity display-name saves, and
  user-block commands now each check cancellation after an external response
  but before mutating view state. Dedicated non-cooperative fakes cancel at
  that exact late-success boundary and prove a dismissed or superseded screen
  neither reports a stale success nor overwrites the current value. This is
  local client lifecycle evidence only, not a remote delivery or deployment
  guarantee.
- 2026-07-27: the native `IMV2ClientKit` suite passed **122 tests in 26
  suites**. Every durable command outbox now checks cancellation after a
  non-cooperative transport returns and before it writes a local acceptance,
  rejection or retry outcome. A focused message-outbox regression cancels at
  that exact late-success boundary and proves the pending command, including
  its original idempotency key, remains unchanged for the next reconnect. This
  is local client lifecycle evidence only, not a remote-delivery guarantee.
- 2026-07-27: the selected iPhone 17 / iOS 26.2 Simulator passed the full
  shared `IMApp` scheme with **62 Swift tests** and **2 UI tests**, zero
  failures. The app now releases its foreground realtime-start task after it
  succeeds, fails or is cancelled. A generation-fenced gate prevents a stale
  cancelled task from releasing a newer attempt, so a transient startup
  failure cannot leave an already-completed task blocking a later foreground
  retry. Focused tests cover both release and stale-completion fencing. This
  fix also passed the dedicated local-account UI suite (**3 tests**) through
  real HTTPS registration, device-credential issuance, Keychain session
  creation and scoped cleanup. It remains local Simulator lifecycle evidence
  only, not multi-device product E2E or a signed-device result.
- 2026-07-27: the same iPhone 17 / iOS 26.2 Simulator passed the full shared
  `IMApp` scheme with **60 Swift tests** and **2 UI tests**, zero failures.
  iOS now constructs independent member-mute and audited-member-removal
  outboxes, replays both in bounded availability-driven runtime passes, and
  exposes owner/admin controls with task cancellation and a destructive-action
  confirmation. Store tests prove that mute carries the bounded
  `ADMIN_ACTION` audit reason and future expiry, audited removal uses its own
  boundary then refreshes the roster, and terminal moderation codes remain
  opaque. This is local single-device evidence only, not multi-device product
  E2E or an authorization bypass of the server.
- 2026-07-27: the caller-selected, manually booted iPhone 17 / iOS 26.2
  Simulator passed `xcodebuild test -project IMApp/IMApp.xcodeproj -scheme
  IMApp -configuration Debug -destination 'platform=iOS Simulator,id=…'` with
  **57 Swift tests** and **2 UI tests**, zero failures. This includes the new
  public-handle user-block/undo flow (durable social outbox, opaque terminal
  errors) and bounded group mention flow (`@all`/exact handles resolved to no
  more than 20 opaque targets before message enqueue). The full disposable
  PostgreSQL Core/Server regression also passed through
  `docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm --build
  swift-tests`, covering compilation of the directory rule that preserves a
  caller's own unblock path while keeping reverse blocks opaque. This is local
  correctness evidence only; it does not prove two-device E2E, accessibility
  manual review, media-provider integration, throughput, or deployment.
- 2026-07-27: on the caller-selected, manually unlocked iPhone 17 / iOS 26.2
  Simulator, `bash IMApp/Scripts/verify_local_account_registration_e2e.sh`
  passed twice consecutively using the project’s `Sign to Run Locally` Debug
  signing, without resetting, erasing or closing that simulator. The dedicated
  UI target created a random local password account through the real HTTPS
  edge, exchanged its device-bound assertion for credentials, committed the
  Keychain-backed session and displayed the signed-in conversation surface.
  Each pass used a new DEBUG-only device and local-storage namespace, leaving
  the simulator’s ordinary V2 Keychain/session/database untouched. The same
  destination then passed the complete shared `IMApp` scheme: **53 tests**,
  zero failures and zero skips, including all App unit tests and both
  deterministic offline UI paths. This is local Simulator integration evidence
  only, not a signed-device, production WebAuthn, APNs, multi-device or
  capacity approval.
- 2026-07-27: `bash IMV2/scripts/verify_v2_local_account_stack.sh` detected a
  stale, in-memory gateway TLS leaf after the local Caddy edge had renewed its
  certificate. Its preflight safely recreated only Caddy and the gateway,
  retained the PostgreSQL/account containers and named volumes, then passed
  the full HTTPS account, two-account TLS 1.3 direct-message/`SyncPull`, rate
  limit, Push, operator and metrics black-box checks. This proves local
  recovery for that certificate-lifecycle case, not production certificate
  rotation or availability behavior.
- 2026-07-27: local Compose launch, migration, smoke and iOS-E2E helpers now
  remove inherited `IM_V2_*` exports before invoking Docker Compose, making
  the ignored, mode-`0600` `.env.local` file the sole local V2 configuration
  source. The read-only precedence regression injects a conflicting edge
  secret into the caller shell and verifies that rendered Compose configuration
  is unchanged. This prevents accidental cross-project terminal state from
  silently splitting account, gateway and edge secrets; it is not a production
  secret-manager substitute.
- 2026-07-27: the current local account stack again passed
  `bash IMV2/scripts/verify_v2_local_account_stack.sh`: HTTPS input validation,
  password registration/device credential issuance, TLS 1.3 direct-message
  delivery and `SyncPull`, password failure limits, Push endpoint contract,
  account disable and loopback metrics all succeeded. The same working tree
  passed `docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm
  --build swift-tests`: **42 Core tests**, **193 Server tests in 51 suites**,
  SQL/protobuf/schema readiness checks and Prometheus rule/config validation.
  This is repeatable local correctness evidence, not a deployment, APNs, or
  throughput/capacity claim.
- 2026-07-26: the current V2 sources passed the generic iOS Simulator
  `build-for-testing` command under Xcode 26.6 with isolated DerivedData and
  code signing disabled. It compiled the `IMApp`, `IMAppTests`, and
  `IMAppUITests` bundles for both simulator architectures without creating or
  booting a device. `IMApp/Scripts/verify_generic_simulator_build.sh` records
  this repeatable compile-only baseline. It does not execute tests; the
  separately recorded selected-Simulator runtime baseline is the evidence for
  UI execution and accessibility semantics.
- 2026-07-26: current `main` rebuilt the disposable local account, TLS
  gateway, PostgreSQL and loopback-operator stack, then passed
  `bash IMV2/scripts/verify_v2_local_account_stack.sh`. The black-box check
  verified invalid HTTPS input (`400`), password registration and device
  credential issuance (`200`), then two independently issued credentials
  completed real local-CA-verified TLS 1.3 framed Protobuf sessions. One user
  opened a direct room and had a message accepted; the other observed that
  exact message through `SyncPull`. The same run also verified shared
  password-failure lockout (`401` then `429` with
  `Retry-After` and `no-store`), Push endpoint register/remove (`204`),
  loopback operator account disable followed by access/refresh rejection, and
  private metrics vocabulary. The protocol probe runs only in the local gateway
  container and prints no credential or identity. This is reproducible
  local-stack evidence only; it does not establish production deployment,
  external Push delivery, real-device passkey operation, iOS UI or multi-device
  behavior, or workload capacity.
- 2026-07-26: the local release-stack launcher now performs its narrowly
  labelled dangling-build-stage cleanup both after a successful Docker build
  and from its exit trap when that build fails. A controlled failed-build
  regression preserved the original failure status while making the second
  label-filtered prune call; a real cold release rebuild then passed the full
  account-stack black-box verification with no labelled dangling stage left.
  The cleanup cannot select tagged images, containers or volumes, and remains
  local-development hygiene rather than production image-retention policy.
- 2026-07-26: `main` reran the disposable PostgreSQL Server regression
  (**190 tests / 50 suites**). It includes the direct-profile propagation
  recovery: a display-name update atomically creates its source outbox row,
  retries an expired pre-checkpoint lease without duplicating the user-sync
  record, pages two direct peers under a one-recipient budget, checkpoints only
  after each target reaches its current shard, and completes without a later
  replay. This is durable correctness evidence for the direct-contact graph;
  it is not a multi-device or profile-propagation capacity claim.
- 2026-07-26: the native client now explicitly owns its foreground realtime
  lifecycle. A scene entering `background` cancels the app-owned connection
  task and stops the TLS runtime; a later `active` scene reuses the signed-in
  local projection and makes one new handshake/sync attempt. Temporary
  `inactive` transitions are deliberately ignored because passkey and system
  permission UI can produce them while the app remains foregrounded. A
  generation fence prevents a stale connection's terminal-authentication
  result from signing out a newer session. Cancellation is also checked after
  the handshake and before each initial sync/outbox stage, so a background
  transition cannot continue initial durable work through a non-cooperative
  connection completion; repeated stops do not repeatedly close an already
  stopped connection. ClientKit's full local package suite passed (**119 tests
  / 26 suites**) including stop-then-reconnect and handshake-cancellation
  regressions, and the generic iOS Simulator app/test-bundle build passed with
  Xcode 26.6. On `main` at `45739a6`, all **42** focused
  `V2ConversationStoreTests` passed on an iPhone 17 / iOS 26.2 arm64
  Simulator, including stale-refresh suppression for both delayed successes
  and delayed failures, plus cancellation checks that
  prevent direct/group creation from continuing after a non-cooperative
  identity-directory response, plus privacy-preserving rejection feedback and
  rate-limit retry guidance for direct messages, one-at-a-time durable
  submission for a repeatedly tapped send control, and an empty direct room
  remaining discoverable with its authorized display name. A projection-derived
  room kind also gates group-only member management, so direct and not-yet-profiled
  rooms never expose a nonfunctional group-members entry. Group-member directory
  loads are single-flight, preventing an overlapping refresh from treating the
  same page as corrupt duplicate data; member mutations are likewise
  single-flight, so two actions cannot race on one membership revision. The
  group-members sheet owns and cancels its mutation task on dismissal, with a
  post-directory cancellation fence that prevents a late identity lookup from
  creating a new membership command. The same simulator then passed all
  **48** `IMAppTests` cases and the deterministic fresh-launch
  `IMAppUITests` case (zero failures or skips), covering that revision's
  complete scheme test inventory. `461d0f2` subsequently changed only the
  SwiftUI VoiceOver structure of attachment/removal and reaction controls.
  A transient CoreSimulator host-death/temporary-device condition then
  prevented that historical rerun; it is no longer a current verification
  blocker. On 2026-07-27 the caller-selected iPhone 17 / iOS 26.2 destination
  completed the full shared `IMApp` scheme with **51 passed**, zero failures
  and zero skips. This resolves the local simulator baseline only; it remains
  neither signed-device nor production-network evidence.
- 2026-07-26: `main` at `31b2be1` passed the disposable PostgreSQL Server
  regression (**190 tests / 50 suites**) after adding the gateway
  device-revocation startup cursor test. A gateway node ID seen for the first
  time inserts its cursor at the pre-listener revocation-event watermark, so
  a scale-out replica with no live sockets does not replay append-only
  history; an existing cursor is never advanced at startup and therefore
  keeps crash recovery work. The runtime rejects unbounded/unsafe node IDs,
  and the regression proves events committed after the watermark remain
  consumable. This is database and runtime correctness evidence, not a
  multi-replica capacity result.
- 2026-07-26: `main` at `704920a` rebuilt the complete local account,
  gateway and loopback operator stack from a multi-stage Linux image. The
  final image contains only release runtime artifacts (no server source,
  SwiftPM checkouts or `.build/repositories`) and measured 1.54 GB on this
  machine, down from about 2.25 GB for the former runtime image. The black-box
  local verification passed HTTPS invalid-input handling, password
  registration/device issuance, shared failure-rate lockout, Push endpoint
  register/remove, account disable and old-credential rejection, TLS 1.3,
  and private metrics. This avoids local Docker disk exhaustion during
  repeated verification; it is not a production container-hardening claim.
- 2026-07-26: with Xcode 26.6, the `IMApp` Debug app and test bundles built
  for the generic iOS Simulator. All `IMAppTests` passed on an iPhone 17 /
  iOS 26.5 arm64 Simulator, and the focused conversation-store, Push-wake and
  launch UI tests also passed on the dynamically selected compatible
  simulator. `1286b67` changed the then-checked-in test automation to derive
  the deployment target and choose an available iPhone runtime at or above that
  target, preventing a host with older installed runtimes from selecting an
  incompatible simulator. This remains simulator evidence, not real-device
  Push, passkey or production-network evidence.
- 2026-07-26: on an iPhone 17 / iOS 26.2 arm64 Simulator, the current
  `IMAppLaunchUITests` passed both signed-out entry paths: password sign-in
  controls and password registration. The registration regression proves the
  public ID and display-name fields are present and that submit stays disabled
  until all four required password-registration values are supplied. It uses
  stable accessibility identifiers and a DEBUG-only launch argument; it does
  not contact the account service or change Release behavior.
- 2026-07-25: isolated PostgreSQL Server regression passed **186 tests / 50
  suites** after adding the `0019_account_disable.sql` release artifact. The
  new regression proves a dedicated operator principal can make exactly one
  durable account-disable fact, atomically revoke two device access/refresh
  credential families, invalidate both gateway authentications, reject a
  prior account assertion's credential replay and reject refresh. It also
  proves same-operation retries are idempotent, a reused operation ID for a
  different user conflicts, and a second operation for the already-disabled
  user creates no duplicate audit fact. This is isolated database evidence;
  an approved operator-access path and recovery policy are still required.
- 2026-07-25: the V2 static migration gates now cross-check every numbered SQL
  migration against both the all-service startup schema gate and the retained
  local-volume ledger marker. A newly added migration cannot silently omit
  either check; the marker remains an explicitly reviewed immutable schema
  fact, rather than a reason to re-run historical non-idempotent SQL. This
  protects local development recovery only and is not a production migration
  runner or release approval.
- 2026-07-25: isolated PostgreSQL Server regression passed **183 tests / 49
  suites** after adding password-factor audit facts, password-registration
  transport validation, mandatory account-edge proof, and a cross-replica
  client request budget. Registration, rejected bcrypt verification and
  successful assertion each commit their minimal audit record atomically with
  the relevant account/rate-limit state; the record has no account handle,
  password, verifier, assertion or forwarded client IP. A malformed password
  registration remains a `400` client error instead of being misreported as a
  dependency outage; the edge-budget middleware preserves downstream route
  statuses instead of rewriting an allowed route's `4xx` as `503`. An account
  route rejects a direct caller unless the HTTPS
  edge supplies both its shared proof and exactly one valid edge-generated
  address; PostgreSQL retains only a keyed HMAC digest and bounded cleanup
  removes expired windows. This is implementation evidence only: production
  trusted-proxy/DDoS policy, audit-reader authorization, account recovery and
  human-disable operator-access approval/exercise remain release blockers.
- 2026-07-25: a retained local account-stack PostgreSQL volume was migrated
  through `0019_account_disable.sql`; a newly built Linux
  account/gateway/operator image containing the credential fence passed the
  real HTTPS smoke path: invalid input (`400`), two password registrations,
  five rejected assertions and no-store lockout, device credentials, Push
  endpoint register/remove, TLS 1.3 and private metrics. The separate
  operator process has no host-published port; the script reaches its
  loopback listener with its dedicated local bearer, receives `200 no-store`
  for a single disable operation, then proves the already-issued access token
  and refresh credential both receive `401` and a still-valid, pre-disable
  account assertion receives `403` when it attempts new credential issuance
  through the public HTTPS path.
  The HTTPS edge injected both the account-edge proof and derived client
  address; its loopback account process would reject that public path without
  the proof.
  The aggregate audit table contained two registration
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
- 2026-07-27: the opt-in 100,000-member full-drain regression passed in
  **198.857 s** in the local isolated Docker/PostgreSQL environment. It
  completed every per-recipient sync and inbox projection, released all 100
  completion units and the source admission reservations. This remains
  single-instance durable-correctness evidence, not a throughput or production
  capacity result.
- 2026-07-27: the opt-in 100,000-member worker-interruption recovery soak
  passed in **199.876 s** in that same isolated environment. It recovered
  every completion unit after each checkpoint and terminal-release interruption
  boundary without duplicate projections, missing targets or post-release
  claims. This is likewise correctness evidence only.
- 2026-07-26: the local account/gateway smoke verification passed account
  HTTPS, password failure lockout (five `401` responses followed by no-store
  `429` with a positive `Retry-After`), device credential issuance, no-store
  Push endpoint registration and deletion, TLS 1.3, and private loopback-only
  metrics. It also proved a two-account direct message was accepted and then
  observed by the recipient through `SyncPull`.
- 2026-07-27: the complete local `xcodebuild test` baseline on a booted
  iPhone 17 / iOS 26.2 arm64 Simulator passed **60** Swift tests in five
  suites and **2** UI tests. The local Swift server suite also passed **193**
  tests in 51 suites, including the filesystem provider's signed
  upload/scan/download/purge lifecycle and EICAR rejection fixture.
- 2026-07-25: a booted iPhone 17 / iOS 26.5 arm64 Simulator passed all **31**
  focused `V2ConversationStoreTests` and `V2PushWakeSettingsTests` tests, with
  zero failures or skips.

The architecture's mandatory initial decision set is tracked in
[`ADR-REGISTER.md`](ADR-REGISTER.md). A pending ADR is a release blocker for
its feature, not permission to silently select product or operational policy.

| Specification area | Current evidence | Status | Release evidence still required |
| --- | --- | --- | --- |
| TLS framing, authentication, send, idempotency | `IMV2Core`, `IMV2Server`, `IMV2ClientKit` frame/session/send modules; the uncompressed first-release protocol fail-closes on every nonzero frame flag before protobuf decoding, and each decoder applies an explicit protobuf nesting limit (gateway runtime configuration or the ClientKit first-release ceiling). The V2 trusted account/device boundary durably registers a device, issues opaque device-bound credentials, encrypts only bounded refresh-operation replay results, and revokes the device on refresh reuse under a different operation ID. Account factor results are now device-bound short-lived HMAC assertions; the Vapor device endpoint rejects an assertion used for a different device. ClientKit includes the primary AuthenticationServices Passkey adapter and no-store WebAuthn HTTP ceremony adapter; the fallback password adapter sends an explicit device ID, never persists the password, and its server route stores only worker-pool bcrypt verifiers with a same-cost dummy check. Password failures use a PostgreSQL-persisted canonical-handle window shared by account-service replicas; a lockout returns no-store `429` with the durable `Retry-After`. The loopback account service also requires a 32-byte shared proof plus exactly one syntactically valid client address injected by the HTTPS edge, rejecting direct/duplicate/malformed forwarding context before any route. A second PostgreSQL fixed window protects every account route across replicas; it stores only an HMAC-derived address key and removes expired rows in bounded `SKIP LOCKED` batches. The separate loopback operator process now accepts one account-disable operation only with a dedicated bearer/principal: its transaction records the bounded reason and operator fact, fences account credential issue/refresh, revokes all current device credentials and emits every device's gateway revocation event. The per-node gateway worker waits for the NIO channel-close future before advancing its durable cursor, and gates frame processing until the close callback is installed; a focused regression proves a registered live stream is closed before its event is acknowledged. The native ClientKit generic registration adapter persists only the device ID plus pending registration UUID in a device-only Keychain item, and finalizes that UUID only after `V2AuthSession` durably writes the returned credential. Its HTTPS refresh adapter sends the durable operation ID with no-store semantics, maps only 401/403 to terminal logout, and preserves all other failures for retry. A disposable PostgreSQL + Vapor route regression models a lost registration/refresh response with an identical retry, then proves the route replays the same no-store credentials, keeps one device/session and persists exactly one operation per request ID. | Partial | Audited production WebAuthn verifier plus one-time challenge/counter storage; account-service HTTPS listener, approved production trusted-proxy chain and external DDoS/abuse limits, password-audit reader authorization/retention, approved account recovery policy, account-disable bastion/mTLS approval and exercise, HMAC/dummy-hash secret provisioning; real client-to-account-service network E2E evidence |
| Native ordinary chat surface | `IMApp` now composes the V2 Keychain-authenticated session, SQLite projection, TLS realtime runtime, bounded durable-command flushing, conversation list/detail and text composer. It explicitly stops the app-owned realtime task when the scene enters the background and creates one fresh handshake/sync attempt when it becomes active again; it does not confuse temporary `inactive` system/passkey UI with backgrounding, and a generation fence prevents stale terminal-auth failures from logging out a newer session. The UI talks only to injectable data-source/sender/direct-room-opening protocols. A foreground file importer copies an attachment into an App Support staging directory under a security-scoped access window; the Store uploads that copy through an injectable scan-gated uploader, and gives the durable message outbox only its opaque media reference. It never records the provider URL or a local file URL in message data, removes the staged copy only after the send intent is durably accepted or queued, and removes direct-child orphan copies from that controlled directory at the next activation. Message bubbles render opaque attachment references and, on an explicit user action, ask the authenticated edge to re-authorize/download the object before exposing the resulting local file solely through the system share sheet; the View never sees an object-provider target. Direct chat uses idempotent `openDirectRoom`; group creation records a durable operation and initial-member list before invoking `CreateGroupRoom`, then retries that same operation after reconnect. Password registration now creates a separate public `@handle` and display name atomically with the login credential. The App resolves an explicit authenticated exact handle before opening a direct room, creating a group, or adding a group member, so those product entry fields no longer take internal UUIDs. A created group emits a frozen-target, roster-free `room.created` fan-out event; a later member-add event carries the same compact identity plus its membership revision, so both initial and later members persist the title before the first message. Snapshot v11 retains those group facts and, for each active direct room only, the authoritative counterpart profile. Opening a direct room atomically appends one bounded profile projection per participant. A later display-name change atomically creates a control-plane outbox source; the gateway consumes it with a recipient work budget, checkpointing only after a page reaches each routed user shard, so retries are idempotent and forwarding migrations mirror the projection. ClientKit gives that server projection priority over its device-local explicit-lookup cache and reconstructs it on snapshot reset. The group-members sheet performs only an authenticated, seek-paginated roster query when opened, via an injectable reader; it rejects duplicate directory results before rendering. Each bounded roster entry now carries only the member's public handle and display name, which the App renders instead of `user_id`. An explicitly resolved direct identity is durably cached with its returned room on this device and supplies the direct list/detail title; unknown identities fall back to “会话”, never a UUID. Based on the loaded role, it exposes owner-only add and owner/admin non-owner removal controls; mutations are first recorded in the durable membership outbox with the displayed revision, then the roster is reloaded on acknowledgement. A sender may use the message context menu to request withdrawal of an unwithdrawn outbound message; that request is first recorded in the independent withdrawal outbox with the locally projected message revision. An acknowledgement does not optimistically tombstone the UI—the next synced projection remains authoritative. The same contextual action is available for editing a sender's unwithdrawn message: its revision-bound edit is first persisted, rejected edits leave the editor open, and the UI waits for the synced replacement text rather than overwriting its local projection. The conversation query fetches a room's complete reaction set once, aggregates it into emoji counts plus only the current user's membership bit, and renders toggles/add controls without exposing reactor IDs to the view. Reaction changes are independently durable and wait for their synced projection rather than mutating the display optimistically. On viewing a conversation, the App reports its highest visible room sequence through the independent receipt outbox. ClientKit atomically suppresses equal or older watermarks in SQLite, treating pending retries and acknowledged receipts as durable high water, so refreshes and restarts cannot create duplicate viewing operations. The privacy sheet exposes the stranger-message receive preference through the independently durable social outbox. After every availability-driven sync, the runtime replays bounded message, withdrawal, edit, reaction, receipt, social, group-creation, and membership-command queues. App tests cover projection-backed list refresh, queued message feedback, scan-gated attachment send/failure retention and staging-copy/orphan cleanup, re-authorized media download success/failure and opaque cache naming, revision-bound withdrawal/edit, reaction add/remove selection, visible-sequence receipt reporting, handle-based direct/group/member-add actions, roster pagination and revision-bound membership changes, and privacy-setting state. A booted iPhone 17 / iOS 26.5 arm64 Simulator passed all 31 focused conversation-store and Push-wake tests with no failures or skips. A separate two-install UI E2E registers independent App installations on two selected simulators, terminates the receiver, sends through the sender's normal direct-message UI, then restores only the receiver's scoped Keychain/SQLite state and verifies a delivered message row after authenticated catch-up. | Partial | direct-profile backlog/capacity thresholds；群名单保持按需读取，不做资料 fan-out；APNs/签名设备与生产网络证据 |
| Durable room event, outbox, fan-out, user sync | numbered `IMV2/sql` migrations and PostgreSQL stores; a disposable-PostgreSQL regression abandons both outbox and delivery leases, then proves replacement workers recover them after lease expiry and complete all three durable sync projections. The planner commits each immutable enumeration page, its deliveries and its checkpoint in one transaction; an injected interruption after the first page resumes strictly after that checkpoint, while delivery claims are held until the plan is complete. The final completion-unit release transaction closes the source outbox only after every unit is terminal; the same regression proves it remains nonterminal after an earlier unit completes. Worker failures use deterministic bounded exponential backoff whose initial/max delay, budget and jitter are required deployment inputs; a retry-budget exhaustion changes the durable row to `paused` rather than terminal/skipped. `IMV2OperatorServerApp` is a separate loopback-only, dedicated-secret control plane: its authenticated one-row replay writes durable audit evidence atomically, supports idempotent operation IDs, and only returns paused work to `pending`; its runbook prohibits batch/terminal replay. 当前项目以本机隔离 Docker/PostgreSQL 回归作为有效门禁，不依赖 GitHub Actions；checked-in Prometheus rules make metrics loss and any paused row page `im-v2-platform-oncall`. | Partial | Actual Alertmanager receiver approval, capacity-derived backlog thresholds, and operator-access (bastion/mTLS) deployment evidence |
| Membership and authorization intervals | membership service/store and fan-out target rules; owner-only member add and owner/admin removal of non-owner members are enforced in the same transactional, frozen-audience path. A separate authenticated V2 `ListRoomMembers` seek-paginated directory reads current active membership from PostgreSQL (maximum 100 entries/page) and returns the authenticated actor's current role on every page, so a management UI never needs to enumerate a large roster to decide which controls to show. Roster data is never copied into fan-out or sync events. The local iOS account E2E registers three accounts, creates a group with one initial member over authenticated TLS, verifies the owner and member roster views, revision-fenced owner addition, the added member's updated roster, and that member's successful group message. | Implemented | revoked-history and migration integration evidence |
| Withdrawal, reaction, edit | Core commands, PostgreSQL stores, gateway, sync projection and local outboxes. A multi-connection PostgreSQL regression races edit against withdrawal at the same expected revision: exactly one mutation commits, while the other deterministically reports revision conflict or terminal tombstone; only one operation/event/fan-out plan is added beyond message acceptance. | Implemented | 本机隔离 PostgreSQL mutation suite |
| Read receipt | independent Core/store/gateway/transport/outbox implementation. The PostgreSQL regression proves receipts are monotonic user state and produce no fan-out work; native ClientKit persists a retryable receipt across restart and rejects stale or unpersistable unsigned sequence values rather than advancing its local result or trapping in SQLite conversion. | Implemented | 本机隔离验证；真实设备/后端传输记录 |
| Push wake hints | durable wake outbox, campaign/budget admission primitive and APNs adapter. PostgreSQL records the one-time device-budget admission separately from the provider lease: a provider failure or expired worker lease can be retried/reclaimed without double-spending the device-key budget; a disabled campaign or missing/exhausted budget suppresses only that wake. An authenticated device registers only an opaque APNs token, encrypted with a separate deployment envelope key and bound to a fresh endpoint generation. The native ClientKit HTTPS adapter uses a refresh-fenced bearer/device pair, explicit no-store headers and an injected transport to register/delete an endpoint; it neither persists nor returns the token. The iOS app exposes an explicit background-wake setting (off by default), registers with UIKit only after that choice, forwards the in-memory APNs token to the authenticated adapter, retries deletion after a failed opt-out, and maps a contentless wake back to the existing authenticated sync path. Its build settings distinguish development/production APNs environments, its entitlement requests APNs capability, and a Release configuration gate rejects a non-production Push environment. The APNs worker sends only the generic `content-available` wake payload; it never places room, sender, message, media or token data in the notification. Invalid/unregistered APNs responses fence-disable only the matching endpoint generation and terminally suppress that wake, while transient provider failures release the durable lease for retry. The provider stays disabled unless explicit APNs credentials and the envelope key are supplied at gateway startup. | Partial | Approved eligibility (foreground, muted, user-setting) and campaign policy; campaign planner; Push-enabled App ID/provisioning profile plus real APNs credential/end-to-end evidence and production failure drill |
| Relationships and stranger direct messaging | direct-room creation, recipient setting and transactional stranger admission; a multi-connection PostgreSQL regression proves four concurrent first stranger messages consume at most the configured three-message window (three commits, one limit rejection). Relationship request/accept/reject/remove and private block/unblock commands; durable user-sync records, PostgreSQL integration, ClientKit wire adapter, local projections and durable offline outbox. The complete PostgreSQL snapshot materializer uses one repeatable-read watermark: relationships, the requesting user's blocks and stranger-message preference come from authority, while timeline visibility comes only from that user's delivered sync log. A server-owned stager creates the existing device/generation reset fence; clients never submit snapshot bytes or watermarks. The local iOS account E2E registers two actual accounts, completes request/accept through the authenticated TLS gateway and sends an ordinary direct message, has the recipient set `deny` and proves the sender sees only opaque terminal `FORBIDDEN`, then restores `allow` and proves the same direct room accepts a new message; it separately proves a recipient block denies an existing direct room with the same opaque terminal `FORBIDDEN`, then accepts a message after explicit unblock. With the default local three-message window, it also proves the gateway accepts the first three messages and returns retryable `RATE_LIMITED` for the fourth. | Implemented | 本机账户 gateway E2E |
| Media references and scanning | Core has opaque media IDs, durable upload intents, scan-state transitions, attachment-only message references and snapshot schema v5; PostgreSQL atomically verifies owner + `available` scan state, persists message references and event payloads; the V2 gateway/client protocol and durable client outbox carry only opaque media IDs (never object URLs). Upload authorization is now bound to the authenticated device in a durable grant: a separate fenced exchange verifies the still-active device and `pending_upload` state, accepts only a one-time exact-byte HTTPS provider target in memory, releases a failed provider claim for bounded retry, and requires that consumed grant before the same device can submit completion. Completion creates the bounded scanner outbox item; scanner-provider failure only releases that item, while success atomically marks the object `available` or `failed`. The authenticated upload edge exposes no-store target, completion, and lifecycle-status contracts; ClientKit uses one coherent bearer/device credential pair, uploads exact bytes, then waits for `available` before returning control to a message sender. The App's foreground attachment path stages an importer copy locally and admits its opaque reference to the message outbox only after that wait succeeds; failed scans/uploads retain the draft and local copy for an explicit retry. The App's explicit download path re-authorizes through ClientKit on every request, writes through a random temporary cache file, then atomically replaces an opaque SHA-256-named App Support cache entry; the managed directory and each file are backup-excluded and use foreground-only file protection, and only interrupted temporary files are cleaned at activation. The authenticated media service issues a short-lived opaque per-device download session only after rechecking the active device, current room membership, unwithdrawn message, and the user's actually delivered `message.accepted` projection. A fenced provider-session service atomically claims one session, repeats that authorization at exchange time, and can return a single provider target only in memory; failed provider issuance releases the session while successful issuance consumes it. A framework-neutral `GET /v2/media/{mediaID}` handler contract validates the path ID and emits a short-lived HTTPS-only JSON target envelope. Its Vapor adapter reuses device-bound bearer authentication, maps unauthorized/unavailable media to opaque responses, and emits no-store JSON; native ClientKit resolves it locally with a coherent bearer-token/device pair, no-store semantics, no automatic retry, explicit HTTP errors, and then directly transfers object bytes with URLSession. The runtime schedules the bounded PostgreSQL retention worker using an explicit withdrawn-reference interval and a separately configured low-frequency maintenance cadence; it uses `SKIP LOCKED` to terminally expire eligible objects and emit a privacy-safe provider cleanup outbox record. A separate fenced worker retries only provider byte deletion. For local-only verification, `V2LocalFilesystemMediaProvider` now signs short-lived exact-byte HTTPS targets, writes opaque UUID-named objects atomically in a private directory, supports re-authorized reads and purge, and moves blocking file I/O off the cooperative executor. `V2LocalEICARMediaScanner` gives the scan worker a reproducible pass/fail fixture; it detects only the harmless EICAR test string and is explicitly not production malware protection. | Partial | Production object provider/scanner configuration, public media listener composition/auth rate limits, approved background-transfer/relaunch policy, retention and abuse-load tests |
| Mentions | Frozen server visibility authorization (owner/admin-only `@all`, non-enumerating user-target rejection), immutable command/idempotency fields, PostgreSQL `message_mentions` rows, gateway protobuf fields, and ClientKit outbox + incremental/snapshot message projections (schema v6). The full snapshot materializer replays the immutable mention set embedded in each user-delivered message-acceptance event, so later membership changes cannot expand history visibility. | Partial | suppression-aware private notification/push, production PostgreSQL integration/capacity evidence |
| Moderation | ADR-001 standard-chat policy; tested Core/service contracts; PostgreSQL owner/admin explicit message-redaction transaction with privacy-safe audit retention, canonical tombstone, fan-out/outbox and idempotent replay; generated V2 protobuf and authenticated gateway command; native client inbound tombstone projection and durable redaction outbox. The local sync dispatcher treats `message.redacted` as the same terminal tombstone shape as author withdrawal before advancing its cursor. Room-freeze and active-mute state are authoritative send-admission checks. Owner/admin mute is a distinct PostgreSQL transaction with durable operation/audit/event/fan-out/outbox and idempotent replay; generated protobuf, authenticated gateway routing and native client transport are implemented; incremental client sync persists its privacy-safe moderation projection before ACK. The native client also durably queues mute commands, retries with the same operation ID after restart, normalizes wire-millisecond deadlines, and terminally rejects expired commands. Snapshot schema v11 carries privacy-safe mute, room-control, delivered group-room identity/revision, and active direct-room counterpart-profile facts; the server materializer replays delivered history and rebuilds only bounded direct state from authority. Server validation forbids duplicate source events or room positions across snapshot pages. A separate, server-to-server trusted-safety service controls room freeze/unfreeze without accepting a gateway actor; each control transition atomically persists state, audit, event, fan-out, outbox and idempotent result. Freeze/unfreeze facts fan out as moderation records and update the native client's durable current room-control projection. Audit-level member removal is a separate protobuf command, moderation operation/audit row and native durable outbox: one transaction changes membership, freezes the pre-removal audience (including the departing user), records a canonical `membership_changed` event, and returns the persisted membership revision on replay. The runtime schedules a bounded PostgreSQL audit-retention worker using `SKIP LOCKED`, deleting only expired audit copies while preserving operation/idempotency records. | Partial | notification/appeal presentation; operational recovery evidence |
| Shard routing/move | a PostgreSQL logical router seeds one explicit default bucket/epoch only when absent, then reads durable per-user write-owner overrides plus optional read-fallback metadata for every planner/delivery batch. Its transactional control-plane cutover is epoch-CAS, operation-ID idempotent and records the operator principal. A worker resolves every claimed target again and, when the route is stale, fence-handoffs that same pending delivery to the current logical write bucket rather than writing old-owner state, duplicating the target, or terminal-skipping it. PostgreSQL integration covers default routing, idempotent/stale cutover rejection, old-to-new bucket handoff with one durable row. `user_shard_migrations` reserves one migration per user; its row-locked PostgreSQL store fences every phase and stores only bounded error categories plus equal fingerprints. The durable coordinator never holds a database transaction across adapter I/O and leaves interrupted attempts observable for retry. A concrete PostgreSQL projection adapter copies receiver inbox, sync log/sequence, device cursor, snapshots/pages and capabilities between independently addressed source/target stores; it pages sync history, verifies canonical SHA-256 fingerprints and supplies an idempotent source cleaner. Gateway and loopback-only operator startup parse a deployment-only physical-bucket registry, verify every declared schema before traffic, and never expose those addresses through records/logs/API bodies. Fan-out writes into the routed target before control completion; during forwarding, direct/social authority writes mirror their already-committed source sync record (including its sequence) to the target and response-loss retry is idempotent. After cutover, direct/social projections allocate their next sequence in the current write owner, so a stale control-store counter cannot collide with target fan-out state. The runtime resolves every sync pull/ack/snapshot operation to the current write owner, never an automatic read fallback. It schedules one bounded delivery pass for every configured logical bucket while preserving a process-wide concurrency cap, and durable-work metrics aggregate all configured delivery buckets. Initial copy/verify reaches `forwarding`; a separate final fingerprint check reaches `verified`, which gates cutover. Two-PostgreSQL-container regressions cover target-commit/control-completion recovery, a TCP-refused target outage with durable retry and exact recovery, direct/social forwarding, post-cutover direct/social allocation after a target fan-out record, and multi-bucket pipeline scheduling. The operator exposes authenticated single-user `copy-verify`, `verify-forwarding`, cutover and retention-window rollback endpoints only. Rollback accepts no bucket, derives source/target from the durable migration, uses a fresh epoch-CAS, is operation-ID idempotent and marks the migration `rolled_back` so cleanup cannot delete the restored source owner. A route cutover still records the default 24-hour rollback retention deadline; the runtime schedules leased post-deadline source cleanup. | Partial | Operator-access deployment evidence and capacity evidence |
| Redis/NATS adapters | Redis is not a V2 correctness dependency. PostgreSQL durable polling is the default. An optional Core NATS publisher is wired when `IM_V2_NATS_URL` and `IM_V2_NATS_SUBJECT` are both present; it publishes only a `(sourceEventID, planID)` wake hint **after** the durable PostgreSQL publisher completes. The wrapper suppresses hint failure, so loss or duplication cannot release work or change a user projection. Configuration rejects a partial endpoint/subject pair. The current minimal adapter creates a fresh connection per hint and writes Core NATS `CONNECT`/`PUB`; it has no consumer, connection reuse/reconnect, NATS TLS/NKey, broker ACK, broker health metric, or real-broker success-path test. A focused Docker regression proves that an injected hint failure leaves durable outbox work publishable; it does not prove broker delivery. | Partial | real-broker publish/consume and loss/recovery integration tests; authenticated/TLS deployment policy; consumer wake integration; metrics/alerts and capacity/failure evidence |
| Observability, deployment, PITR/DR | privacy-safe gateway/fan-out telemetry boundary, structured-log adapter, and deterministic Prometheus exporter. The runtime fans the same closed event vocabulary to logs and metrics, but suppresses all-zero fan-out poll events so the configured 100ms durable-work loop cannot create idle log/metric noise; claim, retry/release, progress and failure facts remain emitted. It exposes only `/metrics` on an explicitly configured loopback listener (`127.0.0.1`/`::1`), never the public realtime/media surfaces; it drops trace IDs and clamps invalid negative counts. Each scrape also reads a process-local connection-registry snapshot and exposes only active authenticated device/connection gauges; a separate gateway transport snapshot adds all-socket count, inbound queue peak, declared-frame-limit violations, and closed connection reasons from a finite vocabulary—never identifiers or labels. The same private scrape reads aggregate PostgreSQL durable-work state: ready/leased/scheduled/**paused** room-outbox rows, ready/leased direct-profile propagation sources, nonterminal fan-out plans, ready/leased/scheduled/**paused** deliveries for the configured logical bucket, per-ready-device sync backlog, reset-pending device count, ready/leased/suppressed Push-wake rows, and the scrape-local gateway node’s unconsumed device-revocation-event count. A separate availability gauge is zero if that database read fails; no bucket, identifier, token, error text, node, user, or device becomes a label. The local logical-restore drill rebuilds `im_v2` from a custom dump and verifies migration-owned retry/audit facts; it is explicitly not a PITR/RPO/RTO claim. Optional NATS hints have no broker-level telemetry yet. See `docs/10-operations/observability.md`. | Partial | NATS hint/shard/capacity metrics, deployed Alertmanager/runbooks, WAL/PITR restore/failover exercises |
| 100k capacity | `docs/09-capacity/standard-100k.md` defines the release gate; the disposable PostgreSQL suite verifies a single 100,000-member fan-out plan pages at 1,000 recipients and writes exact, deduplicated durable accounting. An explicit opt-in isolated regression drained all 100,000 deliveries through the real per-target transaction path, proving one user-sync and consumer-inbox record per recipient, 100 released completion units, terminal plan state, and room/shard reservation release (2026-07-27: 198.857 s in the local isolated Docker/PostgreSQL environment). A separate opt-in recovery soak injects worker loss before the first target checkpoint, after the first target checkpoint, before the final terminal/release update, and after that update for each of those 100 units; lease-expiry replacements again reached exact terminal/release accounting with no post-release claimable work in 199.876 s in that environment (2026-07-27). Runtime fan-out invokes independently bounded planner and delivery worker groups, with aggregate telemetry and PostgreSQL claims fencing cross-replica work. | Unproven | concurrent executable workload, dated topology/results, approved thresholds and failure test report |

## Verification environment

The Core and Server regression runs in an isolated Colima/Docker Compose
environment, with disposable PostgreSQL, through
`docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm --build swift-tests`
(the container entrypoint is `scripts/run_v2_isolated_tests.sh`). The Compose
test container is deliberately capped at two CPUs and 4 GiB; the entrypoint
therefore validates `V2_SWIFTPM_JOBS` and defaults it to four rather than using
SwiftPM's host-dependent parallelism. On 2026-07-26, the full command passed
42 Core tests, 190 Server tests in 50 suites, the SQL migration manifest,
protobuf generated-source comparison, schema-marker/readiness coverage,
Prometheus-rule validation and runtime-example validation. The ClientKit is
intentionally native:
`swift build --build-tests --package-path IMV2ClientKit` succeeds on this Mac.
Native ClientKit tests run successfully when each invocation uses a disposable
SwiftPM scratch directory via
`scripts/run_v2_clientkit_native_tests.sh`; this avoids stale shared-build
signing/load state while preserving the real macOS runtime. The script defaults
to four compiler jobs so the local run does not monopolize the Mac. On
2026-07-26, the complete native ClientKit suite passed 119 tests in 26 suites,
including the receipt high-water restart regression and media authorization
transfer tests. Both disposable PostgreSQL drills—retained local-schema ledger
and logical restore—also passed on 2026-07-26. Its backup-policy test writes
only a uniquely named Application Support child and removes it afterward. No
GitHub Actions workflow is enabled; historical remote results are not current
evidence.

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
files remain untouched. The historical macOS automation first performed the
generic Simulator `build-for-testing`, then dynamically selected and booted an
available iPhone simulator to run both `V2ConversationStoreTests` and
`V2PushWakeSettingsTests` with `test-without-building`. This historical result
is not a current gate.

On 2026-07-25, this baseline was re-verified locally at `12a1948`: `xcodebuild
build-for-testing -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration
Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
successfully built the App, unit-test and UI-test bundles.  The corresponding
`test-without-building` run on the booted iPhone 17 / iOS 26.5 arm64 simulator
also passed every selected `V2ConversationStoreTests` and
`V2PushWakeSettingsTests` case.  This is a local simulator regression record,
not a substitute for a signed-device or production-network E2E result.

At `d0fcae9`, the previously empty `IMAppUITests` target gained deterministic
signed-out entry checks. It passes `-v2-ui-testing-signed-out` only as a process
argument, so the production route still performs its normal Keychain-backed
restore while the UI test does not depend on historical simulator credentials
or a live account service. A DEBUG-only `-v2-ui-testing-password-register`
argument adds the registration-specific check without changing Release
behavior: stable identifiers prove the public ID/display-name fields appear,
and an incomplete submit stays actionable but announces the missing fields,
so assistive technology does not lose the validation path.
The same test target remains part of the local simulator verification scope.

The opt-in `IMAppLocalAccountUITests` suite separately covers a real local
password-registration path. Its DEBUG-only live-local-account startup mode
keeps the ordinary Debug HTTPS/TLS configuration but intentionally skips any
previous simulator Keychain restore, preventing historical credentials from
changing the test's first screen. Each invocation also receives a new test-only
device and storage namespace, so it cannot overwrite the simulator's ordinary
V2 Keychain identity, session or SQLite database and can be repeated without
erasing the simulator. `IMApp/Scripts/verify_local_account_registration_e2e.sh`
starts/reuses the isolated local stack, adds its generated root CA only to a
caller-selected simulator, and runs the local account and direct-delivery
checks with random identities. Besides the registration UI path, it creates
two separately registered accounts, authenticates two TLS framed gateway
connections, opens a direct room, disconnects both parties, persists the
sender's message in its SQLite outbox, reconnects it to replay the immutable
client message ID, then reconnects the receiver and polls its separate SQLite
store until the synced projection contains the accepted message.
The test resides in a separate `IMAppLocalAccountE2ETests`
target and `IMAppLocalAccountE2E` scheme, so the regular UI suite contains no
external-service skip or network dependency. This is local integration
evidence, not a two-App-installation UI flow, signed-device, production
WebAuthn, APNs, or capacity approval.
Before this suite can exercise Keychain-backed registration, the explicitly
selected simulator must have been manually unlocked once after its most recent
boot and the host Mac must be unlocked: the production device identity and
registration-operation items intentionally use `AfterFirstUnlockThisDeviceOnly`.
The script now fails early for a non-booted selected simulator and documents
this security prerequisite rather than misreporting it as an account-service
or TLS failure. Unlike the generic compile-only baseline, this live Keychain
test intentionally preserves the project’s default Debug signing: disabling
code signing removes the application-identifier entitlement required for
Keychain access and is therefore not valid E2E evidence. On the affected iOS
26.2 Simulator/XCTest runtime, a single `typeText` call writes only the first
character into the SwiftUI form fields. The dedicated DEBUG-only live-local
startup mode therefore receives a disposable random registration fixture via
test launch arguments; the test still taps the real submit control and proves
the HTTPS registration, device credential issuance, Keychain commit and local
session activation path. Release ignores this fixture input and has no test
device-identity provider; the ordinary offline UI suite continues to inspect
user-editable form state.

2026-07-27 本机在 iPhone 17 / iOS 26.2 模拟器上执行
`IMApp/Scripts/verify_local_account_registration_e2e.sh` 已通过九项检查：模拟器到本机账户
HTTPS 边缘的 `400` 预检、真实密码注册与设备凭证签发合同、由 UI 点击触发的
“注册 → Keychain → SQLite 本地会话 → 随机 scope 清理”，以及两个随机本地账户通过两条
TLS gateway 连接创建 direct room；随后双方断开，发送端先把消息持久化到自己的 SQLite outbox，
重新认证后以相同 `client_message_id` 重放，接收端也以原设备凭证重新认证并由独立 SQLite 同步
投影确认。另一个实际 gateway 回归由接收方将陌生人消息设为 `deny`，验证发送端仅获终态
`FORBIDDEN`；恢复 `allow` 后同一 direct room 可发送消息。最后一项在默认本机三条窗口配置下
验证前三条陌生人消息可接受、第 4 条返回可重试 `RATE_LIMITED`。outbox 和投影检查都以 100 ms
间隔、最多 5 秒的有界轮询等待，不把空闲或首个 pull 的空批次误判成投递失败。
另有三账户群聊回归：群主创建含初始成员的群，群主和成员各自读取按需成员目录；群主以目录的
成员版本添加第三人，新增成员读取更新后的目录并成功发送群消息。
另一个 direct-message 回归在房间已创建后由接收方拉黑发送方，验证发送端只获终态 `FORBIDDEN`；
接收方解除拉黑后，同一房间恢复发送。
另一个社交回归由两位真实账户完成好友申请和接受，再创建 direct room 并发送普通消息。
脚本还读取 `xcresult`，仅在该套件恰有九项通过、零失败时报告成功，避免测试进程重启时把不完整结果
误报为绿灯。
同次常规 `IMApp` Debug 测试与
`swift test --package-path IMV2ClientKit` 也通过。该回归同时修复了一个客户端生命周期缺陷：
提交认证时根路由切换到“认证中”会使登录 View 消失；登录 View 不再因这次预期的消失而取消
认证任务，只有后续显式提交才会取消前一个认证任务。这是本机客户端正确性记录，不涉及部署、
生产接入或容量结论。

同日，在第二台已解锁的 iPhone 17 Pro / iOS 26.2 模拟器上，同一九项本地账户与投递 E2E 也通过。
`IMApp/Scripts/verify_local_account_dual_simulators_registration_e2e.sh` 将两台明确指定且不同的
模拟器串行执行这项回归，验证各自的信任根、Keychain、注册操作和本地 SQLite scope 彼此独立；
每次执行还验证两份独立账号/TLS 连接之间的 direct-message 最终投影、发送端离线 outbox 重放，
以及接收端断开后的重连同步、好友申请/接受、接收方对陌生人消息的拒收/恢复、私有拉黑/解除与三条窗口限额，以及三账户群聊的创建、成员目录、版本围栏添加与成员发送。该测试中的客户端连接仍由同一 E2E runner 创建，因此它不声称
覆盖两台 App 安装之间的 UI 交互或 APNs 唤醒；后两类回归仍需独立完成。

2026-07-27，`IMApp/Scripts/verify_local_account_two_install_e2e.sh` 在两台调用方明确指定、
已解锁且不同的模拟器上完成了独立 App 安装级回归。脚本为两端各创建随机 Keychain/SQLite scope
和账户，由接收端通过真实注册 UI 建立本地会话后终止进程；发送端再通过普通“新建私聊 → 开始 →
发送”UI 路径投递消息。接收端仅以自己的 scope 重启并完成认证同步，测试确认详情页实际出现投递的
消息行，最后分别清理两端 scope。该回归还发现并修复了账户菜单错误附着在根视图、进入详情页后
遮挡输入区发送按钮的问题：菜单现在属于会话列表的导航栏，不再覆盖会话详情；它也在已登录列表和
消息详情分别执行元素、触达区域、描述、Dynamic Type、文本裁切和 traits 审计；消息详情输入区还
通过了普通对比度审计，低对比度的“添加附件”和“发送”文字按钮已改用高对比度系统主色调。账户菜单
还能实际打开陌生人消息接收设置和公开身份资料页，回归会验证其关键开关/文本框可定位、可操作及可返回
会话列表；同一回归还会通过真实建群命令创建仅自己的随机群聊、打开并关闭成员页后返回会话列表，确保它与新建私聊共享互斥的呈现状态。发送端在普通消息同步投影出现后还会实际打开反应菜单、提交一次 👍 反应并验证持久化同步反馈；长按自己的消息可打开编辑页、实际保存一个变更并等待同步正文更新，随后仍可提交撤回。接收端独立重启后必须看到本地同步投影的“消息已撤回” tombstone，不能继续显示原文。该路径发现消息行容器的 identifier 会覆盖内部反应、编辑和撤回控件；消息行现作为包含子元素的无障碍容器，保留行定位并让每个操作维持自己的稳定 identifier。撤回 tombstone 的次级文字在浅灰气泡上也被普通对比度审计判为不足，现已改用主文字色。它不覆盖 APNs、签名真机、生产网络或容量；VoiceOver 人工阅读顺序、设置页的 Dynamic Type
与高对比度、减少动态效果和 RTL 仍需人工验收。设置页中的陌生人消息、屏蔽、后台同步唤醒和
公开资料的异步成功/失败反馈现已与聊天操作共用 VoiceOver 公告机制；公告本身仍需在启用 VoiceOver
的设备上人工确认。恢复端含真实投递消息的详情页同样执行了该审计；审计驱动修复了添加反应的最小
触达面积、时间戳的 Dynamic Type/对比度，以及空草稿时不应显示低对比度禁用发送操作的问题。

The same baseline audit found that the retired macOS automation called removed
`Makefile` targets and that the Release build phase directly executed a
non-executable validation script. The checked-in local scripts and build phase
now use an explicit shell. Because the local build-settings check declares no
output, Xcode reruns it when Release configuration changes in an incremental
derived-data build. A local production-valued Release build passed after
reading its processed Info.plist; changing its account URL to HTTP failed the
build with `production_v2_account_requires_https`. Local ClientKit verification
uses the Swift tools version declared by its manifest; the local account/gateway
image independently builds with Swift 6.3. Historical remote records are
retained only as historical reproducibility context; they are
not a current gate or production deployment, WebAuthn, capacity, or
disaster-recovery evidence.

On 2026-07-25, `scripts/check_v2_runtime_env_examples.sh` was added to the V2
local verification path. It checks declarations only—never real secret values—across the
gateway, loopback-only account service and loopback-only operator examples.
In particular, the account example now declares the required Push endpoint
envelope key, preventing a documented configuration from failing before the
service binds its listener. This is a deployment-configuration contract, not
evidence of a production secret manager, public ingress, rollback or
disaster-recovery deployment.

The local account stack is separate from those test runners: on 2026-07-25,
`IMV2/scripts/run_v2_local_account_stack.sh` first rebuilt and forcibly
recreated every executable service sharing its stable local image tag, then
completed only after PostgreSQL,
the loopback account issuer, the un-published loopback-only operator, Caddy
HTTPS edge, and the V2 TLS gateway became healthy. Its companion
`verify_v2_local_account_stack.sh` then verified an HTTPS invalid-input
rejection, password registration to device-credential issuance hand-off, and
two independently issued credentials completing local-CA-verified TLS 1.3
framed Protobuf sessions. The sender opened a direct room and accepted one
message; the recipient observed that exact message through `SyncPull`. The
same run also verified five
rejected password assertions followed by a no-store `429` with a positive
`Retry-After`, authenticated Push endpoint register/remove with `204` and
`no-store` (without printing either token), a local-only operator disable with
a dedicated bearer returning `200 no-store` followed by public HTTPS `401` for
both the previously issued access and refresh credentials and `403` for a
still-valid pre-disable account assertion attempting new credential issuance,
a local-CA-verified TLS 1.3 gateway handshake, and the gateway container's
private metrics endpoint. The latter asserts HTTP 200, `no-store`, no
host-published metrics port, the complete durable-work
ready/leased/scheduled/paused metric vocabulary, and Push-wake
ready/leased/suppressed metrics, and the unlabelled
`im_v2_device_revocation_events_pending` gauge; it therefore catches a stale
gateway image that otherwise passes only the TLS health check. No assertion or
credential is printed. This is local integration evidence only; it is not
production WebAuthn, Alertmanager routing, rate-limit, capacity, or release
evidence.

The local account compose stack keeps the authenticated edge's address limit
finite but sets it to 240 requests per 60 seconds. This is only enough headroom
for one full dual-simulator disposable-account E2E run; production admission
limits remain a separate deployment decision and the isolated server suite
continues to verify the rate-limiter contract itself.

On 2026-07-26, the latest Linux release image built from the then-current
`main` application sources (including `5cfaf36`) was forced through that same
local stack and passed the complete smoke script. This confirms the new
per-gateway device-revocation backlog metric reaches the running private
endpoint as an unlabelled numeric sample; it remains local integration
evidence, not a production deployment or capacity conclusion.

The checked-in local-stack scripts can be exercised without developer
credentials or an existing local stack. This is current local evidence only;
it does not require or claim a GitHub Actions result.

Before starting account/gateway, the local stack refreshes PostgreSQL's
read-only SQL bind mount by recreating only the container (the named data
volume is retained), then records numbered SQL migrations in a local-only
`im_v2.local_schema_migrations` ledger. A retained development volume is
bootstrapped from immutable schema markers and receives only missing
incremental SQL; historical non-idempotent migrations are never blindly
re-run and no local data is dropped. This convenience helper is not a
production migration runner. Its disposable regression bootstraps a fresh
volume, removes the `0010` user-shard router control table/ledger row, and
proves that only `0010` is reapplied before a no-op repeat run. The local
verification scripts run that disposable regression with a generated one-time
local environment file; they never consume or write a developer's real
`.env.local`.

The opt-in isolated 100k delivery-drain regression described in
`docs/09-capacity/standard-100k.md` passed on 2026-07-27 in 198.857 seconds.
Its separate 100k lease-expiry recovery soak passed in 199.876 seconds,
simulating all four
checkpoint/terminal-update interruption boundaries for every completion unit.
Both are deliberately excluded from the default suite and the isolated runner
rejects a requested Server-test filter that matches zero tests, so either
command cannot report a false green focused run. They verify durable correctness
at that scale only; no throughput/SLO claim follows from them.

The executable-contract gate also regenerates V2 protobuf bindings in a
temporary directory and checks them against committed sources, then regenerates
`IMV2/sql/migration-manifest.sha256` from the numbered SQL migrations and checks
that manifest. The isolated Core/Server regression executes both checks, along
with local-schema-marker coverage, schema-readiness coverage, Prometheus-rule
validation and runtime-example validation. The native ClientKit run remains
local to macOS.

## Completion rule

The V2 refactor is not complete until every “Missing” and “Partial” row is
implemented or explicitly removed from the approved specification, every
decision-pending ADR is approved, and the stated local/integration/capacity/DR
evidence exists. In particular, a 100k group is not a release claim without a
dated successful load report.
