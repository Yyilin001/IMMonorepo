# D6 room maintenance: implementation and verification

Base: `c9887735b6c2b12812a5929c4bd8c78f7dab753e` (`codex/va-maintenance-d6`).
Canonical schema SHA-256: `676ab232cab093bad27e55719db3cc83931945dbf7625b2823855f033f313cff`.
The tests used a disposable PostgreSQL 16 Alpine container in the separate
`imv2-va-d6-pg` Docker project, not the development stack. No schema change is
part of D6.

## Ownership and fencing

The scanners read bounded room IDs. They neither claim a room nor authorize a
write. `V2RoomActorMaintenanceWorker` dispatches one service-only room command
per candidate. The host must grant the room turn and pass its immutable exact
activation token to `V2ActorRoomMaintenanceExecutor`. Log-floor calculation,
projection-body materialization, floor update, and event deletion share one
PostgreSQL transaction after `v2RequireRoomActivations`. Terminal review-job
and room-operation cleanup uses the same fence and a bounded transaction-wide
row budget. The common helper sets SQL lock/statement timeouts before the room
lock and checks the database clock after acquiring it. `V2RoomTransactionAttempt`
classifies a failed COMMIT as outcome unknown. An old token is rejected after
takeover, including when a scanner saw the room before takeover.

The room-operation table set and its per-table retention predicates are shared
with the existing control cleanup descriptor list. The control store's
`.actorOwned` mode excludes those rows and `content_review_jobs`; its existing
`.legacyOwnerLocked` default is transitional until I1 constructs `.actorOwned`
and replaces the legacy room-log worker. A deployment must not run both room
cleanup modes against the same owner database as independent authorities.

## Maintenance ledger

| Rows/work | Physical scope and writer rule |
| --- | --- |
| `rooms.log_trimmed_through_room_sequence`, `room_events` | Owner room facts; room turn and exact activation fence. Existing active-reader/window floor rule remains. |
| `message_projection_states` body references | Projection representation, not a room recovery authority. Before deleting source events, retention locks **all** states referring to those events and restores `room_event` bodies inline; already-inline payloads stay unchanged. Concurrent compaction uses `FOR UPDATE OF state SKIP LOCKED`. |
| `content_review_jobs` | Claim, provider call, result staging and retry lease stay with the external worker. Violation apply goes through typed trusted-safety room command; a failed call leaves the job retryable. Terminal deletion is a fenced room maintenance turn. |
| Room-owned idempotency rows: `direct_room_operations`, `room_membership_operations`, `message_withdrawal_operations`, `moderation_operations`, `message_edit_operations`, `read_receipt_operations`, `message_reaction_operations`, `group_room_operations`, `room_pinned_message_operations`, `group_announcement_operations`, `group_permission_operations`, `group_role_operations`, `special_account_message_operations`, `room_member_nickname_operations` | Fenced per-room deletion after the existing minimum 35-day window and existing approval/audit dependency predicates. `message_send_completions` and `message_forward_operations` deliberately have no generic expiry proof and remain excluded. |
| `media_scan_outbox`, `media_purge_outbox`, `public_profile_update_outbox`, `read_receipt_preference_propagation_outbox`, `push_wake_outbox`, auth replay/history and presence leases | Control/user workflow rows; existing claim, replay expiry, and bounded cleanup rules remain outside a room actor. A room ID in an outbox payload does not make that outbox a room fact. |
| User preference/contact/profile operation results and device sessions | User/control replay scope; existing rotation and minimum retention remain in control housekeeping. |
| `user_sync_log`, projection checkpoints/versions/effects, sync tokens/receipts/snapshots, user message projection GC | User projection and device sync scope; sequence/checkpoint/expiry guards remain outside room authority. These derived rows do not grant room access or replace immutable owner facts. |
| Account disable/block/policy facts, media bytes, forward export/inbox workflows, push/typing/presence hints | Remain with their own control/user/workflow authority. Admission must recheck durable policy through the room capability where a room decision is made; hints are not completion authority. D2/D3/D5 and I1 own those integrations. |

The body-reference race has two orders. If retention locks the state first,
compaction skips it and cannot find the event after retention commits. If
compaction changes an inline state first but has not committed, retention's
unconditional-by-storage state UPDATE waits for its row lock, rechecks, and
restores the body before deleting the event. A predicate restricted to
`payload_storage='room_event'` would miss the second order under a statement
snapshot. Both orders have explicit PostgreSQL phase-barrier tests.

## Verification

Run from `IMV2Server` with `IMV2_POSTGRES_TEST_DATABASE_URL` pointing to the
disposable local database and `IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1`:

| Command | Outcome |
| --- | --- |
| `swift test --jobs 2 --filter V2RoomActorMaintenanceTests` | Real PostgreSQL tests: five cases for token, retention, both body-compactor lock orders, room cleanup, typed review failure retry. |
| `swift test --jobs 2 --filter 'V2ContentReviewWorkerTests\|roomRetentionMissingReceiptsAndRotation\|room log retention follows active readers'` | Existing review and retention regression tests: 15 tests, two suites. |
| `swift test --jobs 2 --filter roomLogRetentionFollowsActiveReaders` | Existing active-reader retention regression: one real PostgreSQL test. |
| `git diff --check` | Exit 0. |

The root integration must add maintenance to the total RoomRequest/RoomResponse
wire, service-role gate, total executor/Factory, and replace the legacy worker
composition in the app. This branch tests the concrete executor through a
local `V2RoomMaintenanceInvoking` adapter; it does not claim end-to-end remote
RoomRef or fault-harness coverage. The separate review adapter accepts a
typed service-principal RoomRef closure from that composition. No additional
Linux Release build was run for D6; G5 integration owns that complete lane.
