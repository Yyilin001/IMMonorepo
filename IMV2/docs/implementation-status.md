# V2 implementation status and release evidence

设计与组件关系请先看 [V2 文档入口](README.md) 和
[当前系统地图](../../docs/current-system-map.md)。本文件把“实现存在”与“可作为
发布证据”分开记录；未特别说明的本机自动化验证结果不是生产批准。

Last reviewed: 2026-08-16

This is an evidence register, not a release approval. “Implemented” means the
named code path exists and its test target compiles; it does **not** mean a
production environment or 100k workload has been proven.

The project is greenfield: no prior data, client, protocol or local-state
compatibility work is in scope under
[`ADR-000`](00-foundation/ADR-000-greenfield-cutover.md). This does not relax
V2 correctness, security, failure-recovery or release-evidence requirements.

## Latest local verification (not a production release approval)

- 2026-08-16: the post-performance review removed the remaining boundedness
  gaps found in gateway, account, PostgreSQL pagination and native media UI.
  Connection admission and heartbeat renewal now use separate store APIs: a
  heartbeat is one fenced `UPDATE`, while only first admission takes advisory
  locks and counts active leases. Account/device issuance has an account-
  serialized active-device ceiling plus a durable successful-new-device fixed
  window, so changing addresses or account-service replicas cannot grow device
  and revocation cardinality without bound. Group read-receipt readers use a
  sequence-aligned keyset index/cursor, and Hybrid background maintenance
  enumerates only a bounded SQLite keyset page with a durable round-robin
  cursor instead of loading every room ID after each sync. The App stages
  importer bytes through a 64-KiB bounded copy with per-file, directory-byte
  and file-count quotas; avatar preview keeps only an ImageIO-downsampled
  thumbnail, not the original compressed/full-resolution image. Exact durable
  metrics aggregation is coalesced and deployment-cadenced (30 seconds in the
  example) with its existing timeout/LKG fence. CI now requires protobuf drift,
  migration-marker, readiness-table, strict runtime-example, Prometheus and
  Compose-environment gates. Core/ClientKit/Server package suites passed; the
  disposable PostgreSQL run passed **317 tests in 70 suites**, the iOS app
  passed **109 tests in 9 suites**, and the generic dual-architecture Simulator
  test build succeeded. This is local correctness evidence, not production
  WebAuthn/media-provider/APNs/capacity approval.
- 2026-08-14: Snapshot V3 replaced full-history snapshot materialization with
  a durable per-user application-MVCC projection and continuous checkpoint.
  The server builds digest-fenced artifacts in bounded keyset pages with
  resumable leases; failed/expired builds restore the prior generation, and
  MVCC GC protects active artifact/migration baselines. ClientKit validates
  and applies one page at a time into SQLite shadow tables, commits the server
  snapshot ACK before atomically activating live state, persists the exact
  pre-reset cursor for terminal rollback, and resumes an ACK-committed/local-
  activation crash without an old-token pull. Exact ACK replay remains a
  no-op even after the next generation is staged. Core passed **60 tests in
  19 suites**, ClientKit passed **191 tests in 36 suites**, and the complete
  disposable-PostgreSQL server run passed **299 tests in 69 suites**. These
  include Snapshot V3 resumption/GC/cross-generation ACK, expired reset/token,
  incremental ACK response-loss and user-shard transfer regressions.
  The current checkout also passed the generic dual-architecture iOS
  Simulator test build and every migration/protobuf/schema/Prometheus/runtime-
  environment gate.
  The retained-floor compactor no longer enumerates or mutates historical
  devices. Pull serializes with floor publication and lazily stages reset only
  for an active low cursor; a later device may reuse the newest compatible
  artifact still above the retained floor and then incrementally catch up,
  while keeping independent generations/capabilities, and bounded
  housekeeping removes revoked-device state. Compaction still protects
  inclusive receipt/token capabilities and the replay window, preserves
  inbox/control-effect idempotency results, and reclaims ordered-log prefixes
  plus unreferenced shared payloads in bounded batches. R-006 is closed;
  R-007 tracks the separate product retention policy for stable operation
  ledgers/effects, not a reset-process unbounded-memory risk.
- 2026-08-13: a second server lifecycle scan closed three soft-state growth
  paths. Gateway stream callbacks are installed atomically and permanently
  detached at EOF/revocation, breaking the closed-channel retain cycle; live
  outbound hints await their bounded event-loop hop instead of accumulating
  closures behind a non-writable channel. Connection-registry reentrancy
  generations are removed after each mutation, and a 256-connection churn
  regression proves they are not a history ledger. Core NATS cancellation now
  compensates subscriptions removed during connection replay/confirmation,
  validates confirmed live interests by keyed O(1) lookup, and caps foreground
  distinct-room hints at 256. Focused gateway, registry, NATS and Hybrid wake
  suites all pass.
- 2026-08-13: the system-wide performance pass removed the remaining obvious
  online unbounded/N+1 paths. The inbox/archive conversation list now reads a
  trigger-maintained composite ordering projection with 50-row keyset pages,
  hydrating messages, room profiles, direct identities and profile views only
  for the visible page. Contacts now use separate accepted/incoming/outgoing
  relationship indexes and stable 50-row keyset pages, hydrate profiles only
  for the current page, and avoid repeating an exact request count while
  paging. Contact name/handle contains-search now uses a trigger-maintained
  character-gram FTS5 index rather than a `%query%` scan, with pagination and
  profile update/removal regressions. Device inventory and Favorites also use stable keyset
  pages; revoke-all-other-devices is one set-based transaction; direct
  read-receipt opt-out commits one durable propagation job and lets a
  lease-fenced, retryable worker enumerate rooms in bounded pages. Snapshot
  V3 scans a checkpointed application-MVCC projection in bounded keyset pages,
  while housekeeping is bounded and deduplicated per physical
  database/schema. User-shard verification now reads the actual target schema
  and streams its history into SHA-256 rather than constructing a second full
  history array. Core passed 57 tests, ClientKit passed 181 tests, and Server
  passed 279 tests; six focused disposable-PostgreSQL regressions passed, every migration/protobuf/schema/
  Prometheus gate passed, the generic dual-architecture iOS Simulator test build
  succeeded, and iPhone 17 Pro / iOS 26.5 passed 108 app unit tests. The same
  181 ClientKit tests also passed on the isolated Linux/arm64 SQLite 3.37
  baseline; the special-account migration now adds compatible columns and
  enforces their enum domain with insert/update triggers instead of unsupported
  `ADD COLUMN ... CHECK` syntax. Snapshot V3 retained floors, new-device/low-cursor
  reset, stable inbox/effect results, shared-payload reference GC and shard copy/
  fingerprint now make `user_sync_log` prefix compaction safe and bounded.
  The private metrics endpoint aggregates every distinct physical user store
  and reports planner-statistics estimates plus total relation bytes for both
  retained sync history and stable control effects without exact scrape-time
  table counts. The same simulator passed all 4 password-only UI tests.
  The isolated 16-message × 1,000-member capacity smoke completed 16,000 durable
  receiver projections with acceptance P99 114ms, terminal P99 1,909ms and a
  1,925ms pipeline wall, within the repository's local regression ceilings;
  this remains single-host evidence, not a production capacity claim.
- 2026-08-12: the repository-local correctness pass closed the remaining
  privacy, retry, authorization, atomic-cache and verification gaps. The iOS
  app now ships an explicit privacy manifest; conversation projection and
  favorite hydration use bounded SQLite batch reads; the feature composes one
  grouped environment instead of threading dozens of dependencies through the
  view hierarchy; and media downloads configure a same-directory temporary
  file before one atomic replace. Server-side direct-message denial keeps its
  public response opaque while recording the correct private activity, profile
  hydration rejects bilateral blocks, and content review uses fenced leases,
  durable bounded backoff, a paused terminal-for-operator state and validated
  provider findings. Violation findings are staged before authoritative
  redaction, so a crash in between enforcement and job completion resumes the
  same evidence without re-calling a nondeterministic provider. The pass also
  found and fixed an overload-resolution
  recursion in trusted room freeze/unfreeze and added a direct regression.
  `IMV2ClientKit` passed **174 tests in 35 suites**, disposable PostgreSQL ran
  **271 server tests in 63 suites**, and iPhone 17 / iOS 26.2 passed **103 app
  unit tests in 9 suites** plus **4 deterministic UI tests**, all with zero
  failures. Protobuf comments, the numbered SQL manifest/baseline and the
  pinned `macos-26` / Xcode 26.2 CI simulator target now describe the same
  checkout. This is local correctness evidence only; it does not provide
  production WebAuthn, object storage/scanning, APNs, deployment, PITR or
  capacity evidence.
- 2026-08-04: account-edge now has an owner-authenticated, no-store device
  session inventory and durable remote-revocation commands. Registration stores
  a bounded device name/platform and last-active timestamp; a single-device or
  “other devices” command holds the same account lock as credential rotation,
  revokes access/refresh credentials and Push endpoint, and appends the gateway
  revocation event in one PostgreSQL transaction. The native account menu now
  exposes a Login Devices sheet with current-device labelling, refresh,
  per-device logout and logout-all-others confirmation. The new same-account
  dual-simulator script stages two independent Keychain/SQLite installations
  through device list, message projection/edit/withdrawal, group receipt
  persistence, preference sync, offline-outbox reconnect, foreground
  restoration and a per-device snapshot reset. Reset is deliberately exposed
  only on the loopback operator process, with its existing dedicated bearer;
  its operation UUID is the snapshot UUID, so a lost response retries
  idempotently. This checkout has compiled the script and all test targets,
  but no simulator was booted for this review, so it is not recorded as
  executed E2E evidence; two physical-device execution remains required.
- 2026-07-27: UUID identifiers now use Foundation's single canonical spelling
  at every V2 boundary. This prevents the same direct room or account from
  becoming two SQLite keys when a PostgreSQL `uuid::text` value and a room-event
  UUID differ only by letter case. Direct-profile payloads and their
  propagation worker now use that same spelling; the App keeps the signed-in
  identity as `UserID` at the privacy boundary, preventing a differently cased
  self identifier from being blocked and canonicalizing the persisted command
  target. `IMV2Core` (44 tests), `IMV2ClientKit` (138 tests), the selected iOS
  Simulator `IMApp` scheme (87 tests), and the isolated Core/Server regression
  (194 tests) all passed. The optional NATS publisher now bounds both TCP
  connection and `PONG` confirmation to two seconds; the isolated Server suite
  subscribes to a real local NATS broker, verifies one published fan-out hint
  end-to-end, and verifies a silent broker returns through that bound. This is
  local correctness evidence only: it does not validate a long-lived NATS
  consumer, broker outage recovery, or any capacity claim.
- 2026-07-27: the isolated two-install App E2E also passed under the
  `accessibility-xl-rtl` profile. It temporarily enabled each selected
  simulator's largest accessibility content size and system increased
  contrast, launched the App in Arabic RTL, and restored both original
  simulator settings after all seven stages passed. The real group composer
  carrying `@all` now has a contrast audit in that profile. This is local
  accessibility and synchronization evidence only, not device, capacity, or
  deployment evidence.
- 2026-07-27: the isolated local account-stack black-box regression passed
  HTTPS invalid-input handling, password registration and device-credential
  issuance, TLS 1.3 direct-message delivery and recipient sync, password
  throttling, Push endpoint register/remove, account disable/revocation, and
  private durable-work metrics. This is local Docker integration evidence
  only, not capacity or deployment evidence.
- 2026-07-27: message sending now validates group mentions before it starts any
  attachment upload or scan. Invalid input leaves the draft and staged file
  untouched, so a correction does not incur an avoidable provider transfer.
  The selected iPhone 17 / iOS 26.2 Simulator passed the focused conversation
  store regression and the full shared `IMApp` scheme with **83 Swift tests**
  and **2 UI tests**, zero failures. This is local client-path evidence only,
  not capacity or deployment evidence.
- 2026-07-27: a pure group `@all` mention no longer depends on the public
  identity directory: only exact `@handle` targets require a directory lookup,
  while the gateway still makes the final role and membership decision. The
  selected iPhone 17 / iOS 26.2 Simulator passed the focused conversation
  store regression and the full shared `IMApp` scheme with **82 Swift tests**
  and **2 UI tests**, zero failures. This is local client-path evidence only,
  not capacity or deployment evidence.
- 2026-07-27: the two-install local account E2E now sends `@all` through the
  normal group composer, not a test transport, and requires the independently
  restored member installation to render “提及所有人” from its synchronized
  SQLite projection. All seven isolated UI stages passed on the selected
  iPhone 17 and iPhone 17 Pro / iOS 26.2 simulators, including scoped cleanup
  on both installations. This is local two-install synchronization evidence
  only, not capacity or deployment evidence.
- 2026-07-27: the App-level conversation sender now has a regression at the
  protocol-existential boundary for group mentions. It proves that text,
  media and resolved `@user`/`@all` targets reach the durable message outbox
  and the message transport. `V2ConversationSending` requires every sender to
  implement the mention-bearing operation explicitly, so a new sender cannot
  compile while silently relying on a runtime unsupported fallback. The selected
  iPhone 17 / iOS 26.2 Simulator passed the focused sender test and the full
  shared `IMApp` scheme with **83 Swift tests** and **2 UI tests**, zero failures.
  This is local client-path evidence only, not capacity or deployment
  evidence.
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
| Native ordinary chat surface | `IMApp` now composes the V2 Keychain-authenticated session, SQLite projection, TLS realtime runtime, bounded fair durable-command flushing, conversation list/detail and text composer. It explicitly stops the app-owned realtime task when the scene enters the background and creates one fresh handshake/sync attempt when it becomes active again; it does not confuse temporary `inactive` system/passkey UI with backgrounding, and a generation fence prevents stale terminal-auth failures from logging out a newer session. A failed request-level TLS send closes the entire untrusted stream, releases all waiters and follows the same bounded reconnect path. The UI talks only to injectable data-source/sender/direct-room-opening protocols. A foreground file importer copies an attachment into an App Support staging directory under a security-scoped access window; the Store uploads that copy through an injectable scan-gated uploader, and gives the durable message outbox only its opaque media reference. It never records the provider URL or a local file URL in message data, removes the staged copy only after the send intent is durably accepted or queued, and removes direct-child orphan copies from that controlled directory at the next activation. Message bubbles render opaque attachment references and, on an explicit user action, ask the authenticated edge to re-authorize/download the object before exposing the resulting local file solely through the system share sheet; the View never sees an object-provider target. Direct chat uses idempotent `openDirectRoom`; group creation records a durable operation and initial-member list, uploads it through bounded Begin/Append/Finalize pages, and retries the same operation after reconnect. Server drafts cap each actor at three active imports and one group-sized temporary audience, expire after 24 hours, can be cancelled while mutable, are reclaimed by bounded maintenance, and let a resumed client reset its acknowledged page cursor only when the draft was recreated empty. Ordinary sends now share the same one-quantum round-robin schedule as withdrawal, moderation, membership and other control queues, so a large offline send backlog cannot starve them. Password registration now creates a separate public `@handle` and display name atomically with the login credential. The App resolves an explicit authenticated exact handle before opening a direct room, creating a group, or adding a group member, so those product entry fields no longer take internal UUIDs. A created group emits a frozen-target, roster-free `room.created` fan-out event; a later member-add event carries the same compact identity plus its membership revision, so both initial and later members persist the title before the first message. Snapshot V3 projection schema 31 retains those group facts and, for each active direct room only, the authoritative counterpart profile. Opening a direct room atomically appends one bounded profile projection per participant. A later display-name change atomically creates a control-plane outbox source; the gateway consumes it with a recipient work budget, checkpointing only after a page reaches each routed user shard, so retries are idempotent and forwarding migrations mirror the projection. ClientKit gives that server projection priority over its device-local explicit-lookup cache and reconstructs it on snapshot reset. The group-members sheet performs only an authenticated, seek-paginated roster query when opened, via an injectable reader; it rejects duplicate directory results before rendering. Each bounded roster entry now carries only the member's public handle and display name, which the App renders instead of `user_id`. An explicitly resolved direct identity is durably cached with its returned room on this device and supplies the direct list/detail title; unknown identities fall back to “会话”, never a UUID. Based on the loaded role, it exposes owner-only add and owner/admin non-owner removal controls; mutations are first recorded in the durable membership outbox with the displayed revision, then the roster is reloaded on acknowledgement. A sender may use the message context menu to request withdrawal of an unwithdrawn outbound message; that request is first recorded in the independent withdrawal outbox with the locally projected message revision. An acknowledgement does not optimistically tombstone the UI—the next synced projection remains authoritative. The same contextual action is available for editing a sender's unwithdrawn message: its revision-bound edit is first persisted, rejected edits leave the editor open, and the UI waits for the synced replacement text rather than overwriting its local projection. The conversation query fetches a room's complete reaction set once, aggregates it into emoji counts plus only the current user's membership bit, and renders toggles/add controls without exposing reactor IDs to the view. Reaction changes are independently durable and wait for their synced projection rather than mutating the display optimistically. On viewing a conversation, the App reports its highest visible room sequence through the independent receipt outbox. ClientKit atomically suppresses equal or older watermarks in SQLite, treating pending retries and acknowledged receipts as durable high water, so refreshes and restarts cannot create duplicate viewing operations. The privacy sheet exposes the stranger-message receive preference through the independently durable social outbox. After every availability-driven sync, the runtime replays bounded message, withdrawal, edit, reaction, receipt, social, group-creation, and membership-command queues. App tests cover projection-backed list refresh, queued message feedback, scan-gated attachment send/failure retention and staging-copy/orphan cleanup, re-authorized media download success/failure and opaque cache naming, revision-bound withdrawal/edit, reaction add/remove selection, visible-sequence receipt reporting, handle-based direct/group/member-add actions, roster pagination and revision-bound membership changes, and privacy-setting state. A booted iPhone 17 / iOS 26.5 arm64 Simulator passed all 31 focused conversation-store and Push-wake tests with no failures or skips. A separate two-install UI E2E registers independent App installations on two selected simulators, terminates the receiver, sends through the sender's normal direct-message UI, then restores only the receiver's scoped Keychain/SQLite state, verifies the delivered withdrawal tombstone, creates a group containing the sender through the normal initial-member UI and sends a group message. The sender finally restores only its own scope and verifies that group and message after authenticated catch-up. | Partial | direct-profile backlog/capacity thresholds；群名单保持按需读取，不做资料 fan-out；APNs/签名设备与生产网络证据 |
| Durable room event, outbox, fan-out, user sync | numbered `IMV2/sql` migrations and PostgreSQL stores; a disposable-PostgreSQL regression abandons both outbox and delivery leases, then proves replacement workers recover them after lease expiry and complete all three durable sync projections. The planner commits each immutable enumeration page, its deliveries and its checkpoint in one transaction; with the co-located PostgreSQL router, one CTE materializes the bounded revision snapshot, route epoch, completion unit, deliveries and checkpoint together, while `enumerated_target_count` proves final accounting without a delivery-table scan. An injected database failure on page two proves page one is durable and the failed page fully rolls back before an exact resume. Delivery resolves a route once per bounded claim, then preserves the same per-lease epoch comparison and claim-token handoff fence. The final completion-unit release transaction closes the source outbox only after every unit is terminal; the same regression proves it remains nonterminal after an earlier unit completes. Worker failures, including content review, use the deployment-configured deterministic bounded exponential backoff; retry-budget exhaustion changes the durable row to `paused` rather than terminal/skipped. `IMV2OperatorServerApp` is a separate loopback-only, dedicated-secret control plane: its authenticated one-row replay writes durable audit evidence atomically, supports idempotent operation IDs, and only returns paused room-outbox, delivery, or content-review work to `pending`; its runbook prohibits batch/terminal replay. 本机隔离 Docker/PostgreSQL 回归与 GitHub Actions 使用同一包测试、迁移/生成代码/配置门禁；checked-in Prometheus rules make metrics loss and any paused row page `im-v2-platform-oncall`. | Partial | Actual Alertmanager receiver approval, capacity-derived backlog thresholds, and operator-access (bastion/mTLS) deployment evidence |
| Membership and authorization intervals | membership service/store and fan-out target rules; owner-only member add and owner/admin removal of non-owner members are enforced in the same transactional, frozen-audience path. A separate authenticated V2 `ListRoomMembers` seek-paginated directory reads current active membership from PostgreSQL (maximum 100 entries/page) and returns the authenticated actor's current role on every page, so a management UI never needs to enumerate a large roster to decide which controls to show. Roster data is never copied into fan-out or sync events. The local iOS account E2E registers three accounts, creates a group with one initial member over authenticated TLS, verifies the owner and member roster views, revision-fenced owner addition, the added member's updated roster, and that member's successful group message. | Implemented | revoked-history and migration integration evidence |
| Withdrawal, reaction, edit | Core commands, PostgreSQL stores, gateway, sync projection and local outboxes. A multi-connection PostgreSQL regression races edit against withdrawal at the same expected revision: exactly one mutation commits, while the other deterministically reports revision conflict or terminal tombstone; only one operation/event/fan-out plan is added beyond message acceptance. | Implemented | 本机隔离 PostgreSQL mutation suite |
| Read receipt | independent Core/store/gateway/transport/outbox implementation. The PostgreSQL regression proves receipts are monotonic user state and produce no fan-out work; native ClientKit persists a retryable receipt across restart and rejects stale or unpersistable unsigned sequence values rather than advancing its local result or trapping in SQLite conversion. | Implemented | 本机隔离验证；真实设备/后端传输记录 |
| Push wake hints | durable wake outbox, campaign/budget admission primitive and APNs adapter. PostgreSQL records the one-time device-budget admission separately from the provider lease: a provider failure or expired worker lease can be retried/reclaimed without double-spending the device-key budget; a disabled campaign or missing/exhausted budget suppresses only that wake. An authenticated device registers only an opaque APNs token, encrypted with a separate deployment envelope key and bound to a fresh endpoint generation. The native ClientKit HTTPS adapter uses a refresh-fenced bearer/device pair, explicit no-store headers and an injected transport to register/delete an endpoint; it neither persists nor returns the token. The iOS app exposes an explicit background-wake setting (off by default), registers with UIKit only after that choice, forwards the in-memory APNs token to the authenticated adapter, retries deletion after a failed opt-out, and maps a contentless wake back to the existing authenticated sync path. Its build settings distinguish development/production APNs environments, its entitlement requests APNs capability, and a Release configuration gate rejects a non-production Push environment. The APNs worker sends only the generic `content-available` wake payload; it never places room, sender, message, media or token data in the notification. Invalid/unregistered APNs responses fence-disable only the matching endpoint generation and terminally suppress that wake, while transient provider failures release the durable lease for retry. The provider stays disabled unless explicit APNs credentials and the envelope key are supplied at gateway startup. | Partial | Approved eligibility (foreground, muted, user-setting) and campaign policy; campaign planner; Push-enabled App ID/provisioning profile plus real APNs credential/end-to-end evidence and production failure drill |
| Relationships and stranger direct messaging | direct-room creation, recipient setting and transactional stranger admission; a multi-connection PostgreSQL regression proves four concurrent first stranger messages consume at most the configured three-message window (three commits, one limit rejection). Relationship request/accept/reject/remove and private block/unblock commands; durable user-sync records, PostgreSQL integration, ClientKit wire adapter, local projections and durable offline outbox. The iOS Contacts tab renders only those local pending/accepted projections, supports exact-handle add, incoming/outgoing request handling, remove, block, and a direct-chat jump. It hydrates contact cards through a bounded `relationship` profile-read context; a PostgreSQL regression proves no pair is unavailable, a pending pair is readable, and removal revokes that access. UI acknowledgement never creates a speculative friend: the next user-sync projection remains authoritative. Snapshot V3 continuously folds delivered and authoritative facts into the per-user application-MVCC projection; a fixed checkpoint watermark supplies relationships, blocks, preferences and delivered timeline visibility without replaying full history during reset. A server-owned stager creates the existing device/generation reset fence; clients never submit snapshot bytes or watermarks. The local iOS account E2E registers two actual accounts, completes request/accept through the authenticated TLS gateway and sends an ordinary direct message, has the recipient set `deny` and proves the sender sees only opaque terminal `FORBIDDEN`, then restores `allow` and proves the same direct room accepts a new message; it separately proves a recipient block denies an existing direct room with the same opaque terminal `FORBIDDEN`, then accepts a message after explicit unblock. With the default local three-message window, it also proves the gateway accepts the first three messages and returns retryable `RATE_LIMITED` for the fourth. | Implemented | 本机账户 gateway E2E |
| Media references and scanning | Core has opaque media IDs, durable upload intents, scan-state transitions, attachment-only message references and snapshot schema v5; PostgreSQL atomically verifies owner + `available` scan state, persists message references and event payloads; the V2 gateway/client protocol and durable client outbox carry only opaque media IDs (never object URLs). Upload authorization is now bound to the authenticated device in a durable grant: a separate fenced exchange verifies the still-active device and `pending_upload` state, accepts only a one-time exact-byte HTTPS provider target in memory, releases a failed provider claim for bounded retry, and requires that consumed grant before the same device can submit completion. Completion creates the bounded scanner outbox item; scanner-provider failure only releases that item, while success atomically marks the object `available` or `failed`. The authenticated upload edge exposes no-store target, completion, and lifecycle-status contracts; ClientKit uses one coherent bearer/device credential pair, uploads exact bytes, then waits for `available` before returning control to a message sender. The App's foreground attachment path stages an importer copy locally and admits its opaque reference to the message outbox only after that wait succeeds; failed scans/uploads retain the draft and local copy for an explicit retry. The App's explicit download path re-authorizes through ClientKit on every request, writes through a random temporary cache file, then atomically replaces an opaque SHA-256-named App Support cache entry; the managed directory and each file are backup-excluded and use foreground-only file protection, and only interrupted temporary files are cleaned at activation. The authenticated media service issues a short-lived opaque per-device download session only after rechecking the active device, current room membership, unwithdrawn message, and the user's actually delivered `message.accepted` projection. A fenced provider-session service atomically claims one session, repeats that authorization at exchange time, and can return a single provider target only in memory; failed provider issuance releases the session while successful issuance consumes it. A framework-neutral `GET /v2/media/{mediaID}` handler contract validates the path ID and emits a short-lived HTTPS-only JSON target envelope. Its Vapor adapter reuses device-bound bearer authentication, maps unauthorized/unavailable media to opaque responses, and emits no-store JSON; native ClientKit resolves it locally with a coherent bearer-token/device pair, no-store semantics, no automatic retry, explicit HTTP errors, and then directly transfers object bytes with URLSession. The runtime schedules the bounded PostgreSQL retention worker using an explicit withdrawn-reference interval and a separately configured low-frequency maintenance cadence; it uses `SKIP LOCKED` to terminally expire eligible objects and emit a privacy-safe provider cleanup outbox record. A separate fenced worker retries only provider byte deletion. For local-only verification, `V2LocalFilesystemMediaProvider` now signs short-lived exact-byte HTTPS targets, writes opaque UUID-named objects atomically in a private directory, supports re-authorized reads and purge, and moves blocking file I/O off the cooperative executor. `V2LocalEICARMediaScanner` gives the scan worker a reproducible pass/fail fixture; it detects only the harmless EICAR test string and is explicitly not production malware protection. | Partial | Production object provider/scanner configuration, public media listener composition/auth rate limits, approved background-transfer/relaunch policy, retention and abuse-load tests |
| Mentions | Frozen server visibility authorization (owner/admin-only `@all`, non-enumerating user-target rejection), immutable command/idempotency fields, PostgreSQL `message_mentions` rows, gateway protobuf fields, and ClientKit outbox + incremental/snapshot message projections (schema 31). Snapshot V3 preserves the immutable mention set from each delivered message projection, so later membership changes cannot expand history visibility. | Partial | suppression-aware private notification/push, production PostgreSQL integration/capacity evidence |
| Moderation | ADR-001 standard-chat policy; tested Core/service contracts; PostgreSQL owner/admin explicit message-redaction transaction with privacy-safe audit retention, canonical tombstone, fan-out/outbox and idempotent replay; generated V2 protobuf and authenticated gateway command; native client inbound tombstone projection and durable redaction outbox. The local sync dispatcher treats `message.redacted` as the same terminal tombstone shape as author withdrawal before advancing its cursor. Room-freeze and active-mute state are authoritative send-admission checks. Owner/admin mute is a distinct PostgreSQL transaction with durable operation/audit/event/fan-out/outbox and idempotent replay; generated protobuf, authenticated gateway routing and native client transport are implemented; incremental client sync persists its privacy-safe moderation projection before ACK. The native client also durably queues mute commands, retries with the same operation ID after restart, normalizes wire-millisecond deadlines, and terminally rejects expired commands. Snapshot V3 projection schema 31 carries privacy-safe mute, room-control, delivered group-room identity/revision, and active direct-room counterpart-profile facts; the projector preserves delivered state and rebuilds only bounded direct state from authority. Server validation forbids duplicate source events or room positions across snapshot pages. A separate, server-to-server trusted-safety service controls room freeze/unfreeze without accepting a gateway actor; each control transition atomically persists state, audit, event, fan-out, outbox and idempotent result. Freeze/unfreeze facts fan out as moderation records and update the native client's durable current room-control projection. Audit-level member removal is a separate protobuf command, moderation operation/audit row and native durable outbox: one transaction changes membership, freezes the pre-removal audience (including the departing user), records a canonical `membership_changed` event, and returns the persisted membership revision on replay. The runtime schedules a bounded PostgreSQL audit-retention worker using `SKIP LOCKED`, deleting only expired audit copies while preserving operation/idempotency records. | Partial | notification/appeal presentation; operational recovery evidence |
| Shard routing/move | a PostgreSQL logical router seeds one explicit default bucket/epoch only when absent, then reads durable per-user write-owner overrides plus optional read-fallback metadata for every planner/delivery batch. Its transactional control-plane cutover is epoch-CAS, operation-ID idempotent and records the operator principal. A worker resolves every claimed target again and, when the route is stale, fence-handoffs that same pending delivery to the current logical write bucket rather than writing old-owner state, duplicating the target, or terminal-skipping it. PostgreSQL integration covers default routing, idempotent/stale cutover rejection, old-to-new bucket handoff with one durable row. `user_shard_migrations` reserves one migration per user; its row-locked PostgreSQL store fences every phase and stores only bounded error categories plus equal fingerprints. The durable coordinator never holds a database transaction across adapter I/O and leaves interrupted attempts observable for retry. A concrete PostgreSQL projection adapter copies receiver inbox, sync log/sequence, device cursor, snapshots/pages and capabilities between independently addressed source/target stores; it pages sync history, verifies canonical SHA-256 fingerprints and supplies an idempotent source cleaner. Gateway and loopback-only operator startup parse a deployment-only physical-bucket registry, verify every declared schema before traffic, and never expose those addresses through records/logs/API bodies. Fan-out writes into the routed target before control completion; during forwarding, direct/social authority writes mirror their already-committed source sync record (including its sequence) to the target and response-loss retry is idempotent. After cutover, direct/social projections allocate their next sequence in the current write owner, so a stale control-store counter cannot collide with target fan-out state. The runtime resolves every sync pull/ack/snapshot operation to the current write owner, never an automatic read fallback. It schedules one bounded delivery pass for every configured logical bucket while preserving a process-wide concurrency cap, and durable-work metrics aggregate all configured delivery buckets. Initial copy/verify reaches `forwarding`; a separate final fingerprint check reaches `verified`, which gates cutover. Two-PostgreSQL-container regressions cover target-commit/control-completion recovery, a TCP-refused target outage with durable retry and exact recovery, direct/social forwarding, post-cutover direct/social allocation after a target fan-out record, and multi-bucket pipeline scheduling. The operator exposes authenticated single-user `copy-verify`, `verify-forwarding`, cutover and retention-window rollback endpoints only. Rollback accepts no bucket, derives source/target from the durable migration, uses a fresh epoch-CAS, is operation-ID idempotent and marks the migration `rolled_back` so cleanup cannot delete the restored source owner. A route cutover still records the default 24-hour rollback retention deadline; the runtime schedules leased post-deadline source cleanup. | Partial | Operator-access deployment evidence and capacity evidence |
| Redis/NATS adapters | Redis is not a V2 correctness dependency. PostgreSQL durable polling/cursor pull is the default. Fan-out plan hints are published only after durable PostgreSQL completion and failure is suppressed. Hybrid room wake and presence/typing use one reusable Core NATS connection per gateway, dynamically subscribe only to current local interests, replay them after reconnect, and confirm commands with bounded `PING`/`PONG`; cancellation during connection replay or incremental confirmation performs compensating `UNSUB`. Pending acknowledgements, inbound payload dispatch and distinct foreground-room hints all have fixed memory ceilings. The isolated suite covers a real subscriber, silent-broker timeout, broker rejection, concurrent connection sharing and deactivation-during-replay. NATS still has no TLS/NKey or broker/reconnect/consumer-lag telemetry. | Partial | broker restart/network-partition soak; authenticated/TLS deployment policy; metrics/alerts and capacity/failure evidence |
| Observability, deployment, PITR/DR | privacy-safe gateway/fan-out telemetry boundary, structured-log adapter, and deterministic Prometheus exporter. The runtime fans the same closed event vocabulary to logs and metrics, but suppresses all-zero fan-out poll events so the configured 100ms durable-work loop cannot create idle log/metric noise; claim, retry/release, progress and failure facts remain emitted. It exposes only `/metrics` on an explicitly configured loopback listener (`127.0.0.1`/`::1`), never the public realtime/media surfaces; it drops trace IDs and clamps invalid negative counts. Each scrape also reads a process-local connection-registry snapshot and exposes only active authenticated device/connection gauges; a separate gateway transport snapshot adds all-socket count, inbound queue peak, declared-frame-limit violations, and closed connection reasons from a finite vocabulary—never identifiers or labels. The same private scrape reads aggregate PostgreSQL durable-work state: ready/leased/scheduled/**paused** room-outbox rows, ready/leased direct-profile propagation sources, nonterminal fan-out plans, ready/leased/scheduled/**paused** deliveries for configured logical buckets, ready/leased/scheduled/**paused** content-review jobs, per-ready-device sync backlog, reset-pending device count, ready/leased/suppressed Push-wake rows, and the scrape-local gateway node’s unconsumed device-revocation-event count. A separate availability gauge is zero if that database read fails; no bucket, identifier, token, error text, node, user, or device becomes a label. The local logical-restore drill rebuilds `im_v2` from a custom dump and verifies migration-owned retry/audit facts; it is explicitly not a PITR/RPO/RTO claim. Optional NATS hints have no broker-level telemetry yet. See `docs/10-operations/observability.md`. | Partial | NATS hint/shard/capacity metrics, deployed Alertmanager/runbooks, WAL/PITR restore/failover exercises |
| 100k capacity | `docs/09-capacity/standard-100k.md` defines a fixed creation-time split: `standard_fanout` is capped at 5,000 members; `large_group_hybrid` admits 5,001...100,000 and stores ordinary messages once in an ordered room log for cursor pull. The opt-in 100k hybrid regression seeds 100,000 active members, proves ordinary acceptance creates zero fan-out targets/outbox rows, pulls the event, then proves a single explicit mention creates exactly one reliable target (2026-07-28 local four-vCPU/16-GiB profile: seed 747ms, ordinary acceptance 12ms, first pull 7ms, single mention acceptance 3,130ms, whole test 4,132ms). A visible Hybrid detail view opens a subscription on its existing TLS/protobuf connection, catches up by cursor after a metadata-only wake, and keeps a 30-second recovery pull for hint loss; standard rooms stop before any room-log request. PostgreSQL coalesces a room waterline before the optional dynamic NATS routing layer, so a lost or duplicate wake cannot change durable state. Historical full-fan-out drain data is retained as durable pipeline evidence only; it is no longer an allowed new-group mode at that scale. | Partial | foreground end-to-end latency under sustained traffic, approved workload thresholds, representative topology report, NATS outage/reconnect soak, and broader failure test report |

### 2026-07-30 group-creation draft lifecycle correction

The native-chat table's phrase “drafts expire after 24 hours” applies only to
mutable `staging` drafts. A frozen `finalizing` draft is neither expired nor
cancelled, because the immutable member set may already be committing under
the same actor/operation ID. If it has not progressed for 30 seconds, bounded
maintenance replays that exact finalization; the group operation ledger remains
the sole commit fence. Success retains a `completed` result for one hour.
Client cancellation now first becomes durable `cancelling` state and is sent
after reconnect with the same operation ID; only a confirmed cancellation
becomes terminal `cancelled`, which the creation scheduler never reclaims.

### 2026-07-29 standard-group foreground-preview correction

The capacity-table wording that said standard rooms stop before a room-log
request is superseded by the current fixed-mode design in
`docs/09-capacity/standard-100k.md`: an actively displayed standard group may
subscribe and pull an authorization-checked room-event page after a
metadata-only watermark hint. That page is an in-memory, idempotent preview;
it neither writes the Hybrid room cursor nor advances the personal-sync ACK.
Reliable standard delivery remains fan-out → `user_sync_log`. The Gateway
queues the hint after a first accepted group-message transaction, coalesces it
outside the command response path, and treats any local/NATS publication loss
as recoverable by normal sync. Hybrid groups continue to use the durable room
cursor and wake outbox.

### 2026-07-28 fan-out claim-lane measurement

Migration `0020_fanout_delivery_claim_lanes.sql` now separates fresh,
due-retry and expired-lease delivery claims into mutually exclusive indexed
lanes. The runtime gives new work a required, configurable bounded burst, then
alternates recovery-first turns between retry and expired-lease work; an empty
lane falls through within the same poll. Claim tokens, lease fences and the
consumer-inbox exactly-once projection were not changed. The isolated four-CPU
100,000-recipient drain passed in **112.796 s**. In the same PostgreSQL
statement profile, the 401 nonempty fresh claims used **2.462 s** and wrote no
temporary blocks, compared with the prior mixed claim's 9.900 s and 47,037
temporary blocks. This improves the database hot path but is still local
correctness/performance evidence, not a production 100k throughput claim.

### Bounded atomic fan-out delivery batches

The local co-located path now commits up to the required
`IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` (1...128; baseline 128) targets in
one PostgreSQL transaction. A JSON-backed CTE bulk-writes inbox rows, reserves
one contiguous sequence range per user, appends sync-log rows and terminalizes
the lease-fenced deliveries before the aggregate completion-unit counter update.
Failure rolls the entire batch back and every member follows the existing retry
path. Cross-store and forwarding/verified-migration targets intentionally
remain target-first and idempotent rather than claiming false cross-database
atomicity. A fresh four-CPU isolated 100k profile passed on 2026-07-28 in
17,097ms total (11,229ms delivery), versus the prior 72,326ms batch path and
108,325ms diagnostic path; this is local single-PostgreSQL evidence, not a
production capacity claim.

Remote user-shard delivery has a separate required
`IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` (1...256; baseline 256).
It never widens the co-located transaction above: each remote batch first
commits the target inbox/sequence/sync-log transaction and then lease-fences
the control completion. A separate required
`IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY` (1...2; baseline 2)
overlaps only independent 256-target commits from one already-claimed remote
lease set—never competing claims. Completion processing and live hints retain
source-batch order, and a failed batch alone follows the existing retry unit.
The 5,000-member two-database regression completed in 750ms at the checked-in
256/2 setting, compared with serial 256-target samples of 943ms, 957ms and
963ms and serial 128-target samples of 1,043ms and 1,023ms. An attempted
concurrency of three regressed to 871ms and was rejected; injected target
failure and target-outage recovery regressions preserve rollback and
exactly-once semantics.

The delivery lease claim is independently bounded by the required
`IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE` (1...2,000; baseline 2,000). A
four-worker isolated 100k regression on 2026-07-29 recorded delivery drains
of 9,653ms, 10,167ms and 10,171ms with 128-target commits. This replaces the
previous coupling to the 256 generic worker batch: room-outbox and planning
claims remain at their own bound, while delivery performs fewer lease-claim
round trips. The same regression found a completion-unit/plan lock-order
deadlock at the larger claim size; completion counters now finish in a stable
order before terminal plan release begins. No target retry occurred in the
post-fix 2,000-claim samples. These figures are local PostgreSQL evidence, not
a production capacity commitment.

## Verification environment

The Core and Server regression runs in an isolated Colima/Docker Compose
environment, with disposable PostgreSQL, through
`docker compose -f IMV2/docker-compose.isolated-tests.yml run --rm --build swift-tests`
(the container entrypoint is `scripts/run_v2_isolated_tests.sh`). The Compose
test container in the dedicated local capacity profile is capped at four CPUs
and 12 GiB inside a four-CPU/16-GiB Colima VM; the profile pins
`V2_SWIFTPM_JOBS=1` for a repeatable Server cold-compile peak, while the
entrypoint validates any caller-supplied positive value instead of deriving
host-dependent parallelism. On 2026-07-26, the full command passed
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
only a uniquely named Application Support child and removes it afterward.
The checked-in GitHub Actions workflow now runs Swift/PostgreSQL integration,
the pinned dual-architecture iOS build-for-testing gate, iOS unit tests, and
signed-out iOS UI tests; the historical remote results above are still not
current evidence.

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
消息行和撤回 tombstone；随后接收端以发送端公开 ID 创建真实群聊，在按需成员目录确认群主与发送端公开资料都出现后经普通 UI 发送带 `@all` 的群消息；发送端仅恢复自己的 scope 后必须从 SQLite 同步投影看到“提及所有人”。接收端实际进入后台
再重新激活后仍须保留该会话详情和 SQLite 消息投影；发送端只恢复自己的 scope 后必须在自身同步投影中看到该群和群消息，并经普通输入区回复；接收端最后恢复自己的 scope 后必须看到这条成员回复，最后分别清理两端 scope。该回归还发现并修复了账户菜单错误附着在根视图、进入详情页后
遮挡输入区发送按钮的问题：菜单现在属于会话列表的导航栏，不再覆盖会话详情；它也在已登录列表和
消息详情分别执行元素、触达区域、描述、Dynamic Type、文本裁切和 traits 审计；消息详情输入区还
通过了普通对比度审计，低对比度的“添加附件”和“发送”文字按钮已改用高对比度系统主色调。账户菜单
还能实际打开陌生人消息接收设置和公开身份资料页，回归会验证其关键开关/文本框可定位、可操作及可返回
会话列表；设置页另执行元素、触达区域、描述、文本裁切和 traits 审计。三段影响用户隐私判断的说明文字已从脚注改为正文动态字号；注册页的 Xcode `.dynamicType` 审计类别仍会把标准 SwiftUI 提交节点误报为 unsupported，但最大辅助字体与 Arabic RTL 的 focused UI 回归会独立断言账号、密码、公开 ID、显示名称和提交入口均可触达，并执行其余语义/布局审计。同一回归还会通过真实建群命令创建仅自己的随机群聊、打开并关闭成员页后返回会话列表，确保它与新建私聊共享互斥的呈现状态。发送端在普通消息同步投影出现后还会实际打开反应菜单、提交一次 👍 反应并验证持久化同步反馈；长按自己的消息可打开编辑页、实际保存一个变更并等待同步正文更新，随后仍可提交撤回。接收端独立重启后必须看到本地同步投影的“消息已撤回” tombstone，不能继续显示原文。该路径发现消息行容器的 identifier 会覆盖内部反应、编辑和撤回控件；消息行现作为包含子元素的无障碍容器，保留行定位并让每个操作维持自己的稳定 identifier。撤回 tombstone 的次级文字在浅灰气泡上也被普通对比度审计判为不足，现已改用主文字色。它不覆盖 APNs、签名真机、生产网络或容量；VoiceOver 人工阅读顺序、设置页的 Dynamic Type
与减少动态效果及登录页以外的 RTL 仍需人工验收。密码登录与注册页另以最大辅助字体和 Arabic RTL
启动参数执行元素、触达区域、说明、裁切和 traits 审计。设置页中的陌生人消息、屏蔽、后台同步唤醒和
公开资料的异步成功/失败反馈现已与聊天操作共用 VoiceOver 公告机制；公告本身仍需在启用 VoiceOver
的设备上人工确认。恢复端含真实投递消息的详情页同样执行了该审计；审计驱动修复了添加反应的最小
触达面积、时间戳的 Dynamic Type/对比度，以及空草稿时不应显示低对比度禁用发送操作的问题。短消息正文使用最小 44×44 的独立可访问容器；编辑/撤回 VoiceOver 操作则附着在完整消息行，避免单字符文本被错误视作可操作的小目标。Xcode 的 hit-region 审计仍会把单字符静态文本误判为独立控件，因此代表性聊天状态保留完整审计，而双向单字符消息回归验证真实投递与投影，不以该误判作为门禁。

同日，这条双安装回归增加了一个与真实 UI 相同的本地断网阶段：发送端以仅限 DEBUG 的不可达实时端点恢复既有会话，在普通私聊输入区提交单字符消息，必须得到“已安全保存，连接恢复后会重试。”；随后正常恢复同一 SQLite scope，接收端只能依赖自己的认证同步在该私聊详情看到该消息。该检查发现并修复了 UUID 仅大小写不同却被本地 SQLite 视作不同 room key 的问题：`V2Identifier` 对 UUID 文本统一存为 Foundation 的规范形式，且显式 `Codable` 解码也必须经过同一验证/规范化构造器；非 UUID 的不透明 URL-safe ID 保持原样。Core 与 ClientKit 各有针对该边界的回归，双安装脚本的八个阶段均为 1/1 通过。此结果仅是本机 Docker/Simulator 正确性证据，不涉及部署、真机、APNs 或容量结论。

同日，服务端也消除了该格式分歧的源头：新建私聊的初始 counterpart profile 与后续资料变更传播均显式使用 Foundation UUID 的大写线缆形式，和 room event 一致，不再依赖 PostgreSQL `uuid::text` 的小写输出。隔离 PostgreSQL 回归分别验证陌生人私聊的初始投影，以及资料变更向既有对端的有界、幂等扇出；跨分片转发断言也读取并校验该字段。这是本机持久化与协议一致性证据，不涉及任何部署工作。

同日，`IMAPP_LOCAL_TWO_INSTALL_ACCESSIBILITY_PROFILE=accessibility-xl-rtl`
在同两台模拟器上通过完整独立安装回归：它不改变随机账户、Keychain/SQLite scope 或消息断言，
会临时将两台指定模拟器设为最大辅助字体和系统高对比度，并以 Arabic RTL 启动每个 App，退出时恢复原有模拟器设置。注册后的设置页、真实私聊/群聊详情、撤回投影与
前后台恢复均完成既有元素、触达区域、说明、裁切和 traits 审计，以及双向 durable 投递断言。
这构成该 profile 的模拟器自动化证据，并在带 `@all` 提及输入区的真实群聊详情额外执行对比度审计；VoiceOver 人工阅读顺序、减少动态效果和其他语言/页面的 RTL 仍需人工验收。

本地账户注册与双安装回归还会在服务已运行但本地 `rooms-primary/standard` 准入租约过期时，
仅续期该单一测试池并保留有效池不变。这避免本地 Compose 长时间运行后将真实建群错误归因于
网络不可用；生产租约仍由独立控制面负责，不在此本地辅助逻辑范围内。

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
