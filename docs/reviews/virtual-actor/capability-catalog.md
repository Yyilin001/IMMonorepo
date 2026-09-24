# Room Virtual Actor C0 capability and DTO catalog

Source: clean `f1cdd78d6a21bf0ae23da627c0710c65115236aa` business tree, inspected from `8839f6709e961853d377a2b60ba7231c325fc6b4`. This is a migration input, not an implemented Actor contract. Signature references below are the **existing** Swift APIs; their exact declarations appear in the appendix. `C` means command, `Q` query, `K` creation/coordinator, `W` worker. Package ownership follows the task cards. `P` means a durable operation identity exists; retry the *same* identity after an unknown result and reconcile from persistence. `R` means a read may be retried after fresh authorization. `N` means no replay-safe command identity is present; never infer that a lost response means no commit. A source call can throw even when an outcome enum also carries business rejection.

## Existing capabilities to freeze as distinct wire cases

| Case | Existing method and input → result | Stable identity / payload identity | Retry; authorization and transaction boundary | Owner; mapper |
| --- | --- | --- | --- | --- |
| C1 send | `V2RoomWriteStore.accept(V2SendMessageCommand, V2CapacityProfile, V2AcceptanceIdentifiers, Date) → V2SendMessageOutcome`; façade `V2SendMessageService.send(V2AuthenticatedSendMessage)` | `ClientMessageID` scoped by sender+room; request fingerprint includes text/media/entities/reply/forward reference. Generated acceptance/event IDs are local execution data. | P; authenticated sender, current control policy, room membership and media checks; message/room/admission/outbox transaction plus activation fence. | D1; Core command and Server outcome/request to Contracts wire. |
| C2 send batch | `V2AtomicRoomWriteBatchStore.acceptAtomically([V2RoomWriteRequest]) → [V2SendMessageOutcome]`; eligibility/partition/repeated-room methods are local batch planning | Per-item `ClientMessageID`, not one batch identity. | P per item; shared SQL must validate every participant token in stable lock order; unknown shared commit pauses every participating turn. | D1; array envelope with per-item result and partition metadata local. |
| C3 edit | `V2MessageEditStore.edit(V2EditMessageCommand, V2CapacityProfile, EventID, Date) → V2MessageEditOutcome` | `MessageEditOperationID`; message ID, expected revision, replacement text/limit. | P; author and revision under room transaction, admission/event and content-review enqueue. | D1; Core command, Server outcome. |
| C4 withdraw | `V2MessageWithdrawalStore.withdraw(V2WithdrawMessageCommand, V2CapacityProfile, EventID, Date) → V2MessageWithdrawalOutcome` | `MessageWithdrawalOperationID`; message ID + expected revision. | P; author/revision, message tombstone/event/admission atomically. | D1; Core command, Server outcome. |
| C5 reaction | `V2MessageReactionStore.change(V2ChangeMessageReactionCommand, V2CapacityProfile, EventID, Date) → V2MessageReactionOutcome` | `MessageReactionOperationID`; message ID/reaction/action. | P; visible message and member authorization, reaction/event/admission in one room transaction. | D1; Core command, Server outcome. |
| C6 special account send | `V2SpecialAccountMessagingStore.authorizeOutbound` + ordinary send + `record(V2TrustedSpecialAccountMessage, ..., V2SendMessageOutcome, Date)` | Send `ClientMessageID`; audit record is coupled to accepted send identity. | P only if audit reconciliation is retained; account resolution/control authorization outside room; room-scoped audit needs fenced command. | D1+D4; Server trusted request and result. |
| C7 membership | `V2RoomMembershipStore.change(V2ChangeRoomMembershipCommand, V2CapacityProfile, EventID, Date) → V2RoomMembershipChangeOutcome` | `MembershipOperationID`; target/action/expected membership revision. | P; fresh control identity snapshot, owner/member permission and revision, membership/event/outbox transaction. | D2; Core command, Server outcome. |
| C8–C11 group capability | `V2GroupCapabilitiesStore.setPinnedMessage / setAnnouncement / setRolePermissions / changeMemberRole` | `PinnedMessageOperationID` / `GroupAnnouncementOperationID` / `GroupPermissionOperationID` / `GroupRoleOperationID`; each command carries room and content or expected revision. | P; group role policy and member revision must be checked in transaction; room event/admission and operation receipt fenced. | D2; four separate Core command/result wire variants. |
| C12 moderation | `V2ModerationStore.apply(V2ModerationCommand, V2CapacityProfile, EventID, Date) → V2ModerationOutcome` | `ModerationOperationID`; action, target/message, expected message revision, reason. | P; role and content revision in room transaction. | D2; Core command, Server outcome. |
| C13 trusted review apply | `V2TrustedSafetyModerationStore.applyTrustedSafety` and `V2ContentReviewStore.stageViolation` | `ModerationOperationID` derived from durable review job/message version; job lease alone is not room write qualification. | P for room effect; trusted principal sealed at worker adapter, content version and room fence before completing review job. | D2 handler, D6 worker adapter; separate trusted wire case. |
| C14 group nickname | `V2ProfilePresentationManaging.updateOwnGroupNickname(UserID, RoomID, GroupNicknameOperationID, V2ProfileRevision?, String?) → V2GroupMemberPresentation` | `GroupNicknameOperationID`; expected revision and normalized nickname. | P; authenticated current member, revision; nickname + operation row under room fence. | D2, I1 Account HTTP; Server parameter mapper, Core result leaf already Codable. |
| Q1 group nicknames | `groupNicknames(UserID, RoomID, UserID?, Int) → V2GroupNicknamePage` | none; cursor+limit. | R; room member authorization at read turn. | D2; page wrapper mapper. |
| C15 read receipt | `V2ReadReceiptStore.record(V2RecordReadReceiptCommand, Date) → V2ReadReceiptOutcome`; batch `recordBatch([V2ReadReceiptRecordRequest]) → [V2ReadReceiptRecordResult]` | `ReadReceiptOperationID`; room/read-through sequence. | P; room membership and head bounds; room receipt and operation rows fenced. Batch keeps per-row failure contract, not send-style global rollback. | D3; Core command, Server outcome/batch wrapper. |
| Q2 readers | `V2ReadReceiptStore.readers(RoomID, MessageID, UserID, String?, Int) → V2ReadReceiptReadersPage`; candidate/visibility split | none; cursor/page size. | R; message room visibility, read-receipt preference and public identity control recheck. | D3; Core page mapper, no reader identities cached indefinitely. |
| Q3 event pull/subscribe | `V2GroupEventLogStore.pull/subscribe` | durable `afterRoomSequence`; subscription interest is ephemeral. | R; membership and log floor at query; Gateway owns socket and resubscription, Actor owns logical query/interest. | D3; Server page/subscription mapper; NATS hint remains advisory. |
| Q4 member directory | `V2RoomMembershipDirectoryStore.list(V2RoomMembershipDirectoryRequest) → V2RoomMembershipDirectoryPage` | cursor and membership revision, no operation ID. | R; room membership/visibility and revision in query turn. | D3; Server request/page mapper. |
| Q5 role baseline | `V2GroupRolePolicyBaselineReading.readRolePolicyBaseline(RoomID, UserID) → V2GroupRolePolicyBaseline` | none. | R; group reader authorization; preserve revision. | D3; Core baseline mapper. |
| Q6 latest visible | `V2RoomLatestVisibleReading.latestVisible([RoomID], UserID) → [RoomID: V2RoomLatestVisibleResult]` | none; up to 100 rooms in existing recovery path. | R; per-room authorization and partial failure, retain collection SQL/batching. | D3; Server result mapper. |
| Q7 room state/sync | `V2RoomStateReading.states([RoomID], UserID) → [RoomID: V2RoomStateReadResult]`; `V2RoomRecoveryCommandHandling.batch(IMV2RoomSyncStateBatch, UserID) → IMV2Envelope` | cursor/snapshot revision, no operation ID. | R; per-room membership/owner validation, partial unavailable distinct from empty. | D3; Server read result and protobuf boundary mapper. |
| Q8 user room directory | `V2UserRoomDirectoryReading.rooms(UserID, RoomID?, Int) → V2UserRoomDirectorySlice` | pagination cursor. | R; user projection/control boundary with room topology lookup; do not activate every room just to enumerate. | D3; Server slice mapper. |
| K1 direct open | `V2DirectMessagingStore.open(V2OpenDirectRoomCommand, V2CapacityProfile, String, RoomID, Date) → V2OpenDirectRoomOutcome` | `DirectRoomOperationID`; unordered user pair and preallocated stable room ID. | P; creation coordinator before activation, pair lock and bootstrap transaction; subsequent room writes require token. | D4; Core command, Server outcome. |
| K2 group create | `V2GroupMessagingStore.create(V2CreateGroupRoomCommand, ..., RoomID, EventID, Date) → V2CreateGroupRoomOutcome` | `GroupRoomOperationID`; title/class/member set and allocated room ID. | P; creation bootstrap plus control intent/manifest; no ordinary missing-room activation. | D4; Core command, Server outcome. |
| K3 staged group | `V2GroupAudienceImportStore.begin/append/freeze/complete/cancel/recoverableFinalizing` + `V2StagedGroupMessagingStore.createStaged` + creation intent `prepare/finalizeCommitted` | `GroupRoomOperationID`; frozen manifest/member pages and fixed room ID. | P; control draft/intent, room bootstrap and resume idempotently; append/freeze/cancel are coordinator operations. | D4; distinct stage wire cases and Server draft/import/outcome mappers. |
| K4 invite create/revoke | `V2GroupInvitationStore.create/revoke` + `V2GroupInviteDirectory.prepare/finalize` | `GroupInviteOperationID`; token digest, room, policy/expiry. | P; global directory and room invite state coordinated, fresh room membership/role check. | D4; Server persistence DTO, Core invite result; never put secret token in logs. |
| K5 invite preview/submit | `V2GroupInvitationStore.preview/submit` | submit token digest + applicant + durable request identity in persistence request; preview is read. | Preview R, submit P by stored request/receipt; control quota/identity and target room acceptance separated. | D4; Server request/outcome mapper. |
| K6 join decide/cancel | `V2GroupInvitationStore.approve/reject/cancel/pendingRequests` | `GroupJoinDecisionOperationID` for approve/reject; cancel uses persistent request state. | P for decisions; reviewer role, global quota, membership/event and request state atomic where applicable; pending query R. | D4; Server outcome/record page mapper. |
| C16 same-store forward | `V2ForwardMessagesHandling.forward(UserID, V2ForwardMessagesCommand) → [V2ForwardMessageResult]`; target `acceptForwardOwnerValidated` | `MessageForwardOperationID` for request; **each source×target** gets durable `target_client_message_id` and result row. | P per pair; acquire two-room reservation, source visibility and target acceptance under same-store single transaction with both activation fences; siblings independently succeed/fail. | D5; Core command/result mapper; internal source read stays server side. |
| C17 forward replay repair | `V2ForwardMessagesService.clientMessageID/replayedResults/markResult` private methods | same operation + source message + target room pair; saved source room/revision and target client message ID. | P per pair; replay read may batch, but missing `result_message_id` repair must use per-pair reservation/fences, including historical success. | D5; no public raw SQL wire case. |
| C18 cross-owner forward/import | `V2CrossOwnerForwarding.forward(...) → V2CrossOwnerForwardOutcome`; `V2ForwardImportEndpoint.deliver` | `MessageForwardOperationID` and export/inbox/receipt identities; target acceptance uses original target client ID. | P; durable export/delivery/receipt workflow and target import under target room fence; source authorization remains anchored to source snapshot. | D5; Server export/import DTO mapper. |
| Q9 media message visibility | `V2MediaDownloadTargetResolving.downloadTarget(UserID, DeviceID, MediaID, V2MediaMessageLocation?) → V2MediaProviderObjectTarget` | none for authorization query; grant/session has own ID. | R only before grant; control device/account then owner message/membership/content snapshot, lock/recheck before issue and exchange; `message=nil` is media domain path. | D5, I1 HTTP; wire result is authorization decision/locator, never provider target/secret. |
| W1 forward delivery/media recovery | `V2ForwardDeliveryWorker.runOnce`, `V2ForwardMediaImportWorker.runOnce`, export/inbox/receipt stores and compactors | durable export/inbox/receipt/media import job IDs and leases. | P via workflow receipt; scanner/claim external, target import/accepted message uses room turn/fence. | D5; worker adapter and import wire mapper. |
| W2 retention | `V2RoomLogRetentionStore.trimRoomLogs(V2RoomLogRetentionMode, TimeInterval, Date, Int) → V2RoomLogTrimReport` | no per-room operation ID; monotonic floor makes replay safe only after re-evaluating current readers. | N as current batch writer; scan externally, each floor update + event delete in room maintenance turn/fenced transaction. | D6; Server mode/report mapper only for local worker, no public client case. |
| W3 content review | `V2ContentReviewStore.claimPending/validateAndRenew/resolve/stageViolation/scheduleRetry` | message version + durable review job lease; trusted moderation command identity. | claim/retry external; room fact apply P and fenced; never mark job complete before apply. | D6 adapter, D2 moderation. |
| W4 housekeeping | `V2ControlPlaneHousekeepingStore.purgeTerminal(Date, TimeInterval, TimeInterval, Int) → V2ControlPlaneHousekeepingReport` | rotation cursor; per-row existing business operation identity. | N batch; split room-owned operation/content-review cleanup into fenced maintenance, keep user/control/outbox cleanup external with minimum idempotency retention. | D6 after C0 extraction. |

Control/user-domain methods deliberately outside room command dispatch: `setStrangerMessagePermission`, `setUserAddPermission`, `V2ReadReceiptStore.setPreferences`, contact alias update, profile/account disable, conversation pin/archive/mute, favorites, user sync and media upload/provider byte transfer. They can alter **authorization decisions** and require fresh policy/version checks by an activated room, but their own authoritative rows are not room facts. A message media download with a message locator is Q9 even though grant/session rows are media-domain writes. See [writer ledger](writer-ledger.md) for precise tables.

## Serialization and mapper rule

The generic `V2Identifier<Tag>` and several Core leaves implement `Codable`, but **most enclosing command/outcome types do not**. Do not infer wire suitability from `Sendable` or from a Codable leaf. `IMV2Core` owns commands including `V2SendMessageCommand`, `V2EditMessageCommand`, `V2WithdrawMessageCommand`, `V2ChangeMessageReactionCommand`, `V2ChangeRoomMembershipCommand`, `V2ModerationCommand`, `V2RecordReadReceiptCommand`, `V2ForwardMessagesCommand`, `V2ForwardMessageResult`, `V2CreateGroupRoomCommand`; these are `Sendable` without `Codable`. `IMV2Server` owns authenticated façades and outcomes (`V2AuthenticatedSendMessage`, `V2SendMessageOutcome`, `V2MessageEditOutcome`, `V2RoomMembershipChangeOutcome`, `V2GroupNicknamePage`, invitation persistence DTOs, read/recovery pages); they also are generally `Sendable` only. Exceptions must be checked type by type: `V2GroupMemberPresentation`, `V2ContactAlias`, `V2ForwardMessageReference`, and `V2ProfileRevision` are Codable leaves. Contracts should define explicit versioned wire enums; the owning D package maps to/from its Core/Server types and maps each associated-value outcome/error. No DB connection, provider target, closure, control grant, or actor ID crosses RPC.

`RoomID`/`UserID`/`MessageID`/`EventID` are `IMV2Core/Identifiers.swift` aliases of `V2Identifier<Tag>`; domain operation IDs are aliases there too. The [DTO type register](dto-types.json) resolves all **127 distinct named parameter/result types** in the exact signatures plus nested payload and façade types (219 entries total) to target, file and line. It also lists source member declarations/cases and records whether the type explicitly conforms to `Codable` (60 of 219 do; identifier aliases inherit generic conformance). Member extraction is a review aid: computed properties and nested type semantics still require reading source. Protobuf `IMV2*` types are generated in the Server target and are `Sendable`, not Swift `Codable`. A `false` flag means a mapper is required for Contracts JSON/binary Codable envelopes even if an existing protobuf serializer exists. The exact Swift signatures are preserved below so the C0 wire contract can be reviewed against the current API.

## Exact existing protocol signatures

Source extraction lists declared methods, not extension defaults or runtime coverage. Line numbers are from the frozen source tree. Public service façades that construct IDs/time/limits and call these protocols remain owned by their D package. The owner-validated variants are infrastructure adapters, not additional user capabilities.
## V2RoomLatestVisibleReading (PostgresV2RoomLatestVisibleStore.swift:12)
- `func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult]`
## V2ContentReviewStore (V2ContentReviewWorker.swift:152)
- `func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease]`
- `func validateAndRenew(_ lease: V2ContentReviewLease, now: Date, leaseDuration: TimeInterval) async throws -> V2ContentReviewLeaseValidation`
- `func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool`
- `func stageViolation(_ lease: V2ContentReviewLease, finding: V2ContentReviewFinding) async throws -> Bool`
- `func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws`
## V2ControlPlaneHousekeepingStore (V2ControlPlaneHousekeepingWorker.swift:45)
- `func purgeTerminal( now: Date, retention: TimeInterval, idempotencyRetention: TimeInterval, limit: Int ) async throws -> V2ControlPlaneHousekeepingReport`
## V2CrossOwnerForwarding (V2CrossOwnerForwardService.swift:16)
- `func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference, sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome`
## V2DirectMessagingStore (V2DirectMessagingService.swift:119)
- `func open( command: V2OpenDirectRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, now: Date ) async throws -> V2OpenDirectRoomOutcome`
- `func setStrangerMessagePermission( command: V2SetStrangerMessagePermissionCommand, now: Date ) async throws -> V2SetStrangerMessagePermissionOutcome`
- `func setUserAddPermission( command: V2SetUserAddPermissionCommand, now: Date ) async throws -> V2SetUserAddPermissionOutcome`
## V2ForwardExportDelivering (V2ForwardDeliveryWorker.swift:6)
- `func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt?`
## V2ForwardMessagesHandling (V2ForwardMessagesService.swift:7)
- `func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult]`
## V2ForwardWorkReplayStore (V2ForwardWorkOperatorReplay.swift:60)
- `func replay(_ command: V2ForwardWorkReplayCommand, operatorPrincipal: String, now: Date) async throws -> V2DurableWorkReplayResult`
## V2GroupAudienceImportStore (V2GroupAudienceImportService.swift:129)
- `func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft`
- `func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft`
- `func freeze(actorUserID: UserID, operationID: GroupRoomOperationID, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceImport`
- `func complete(actorUserID: UserID, operationID: GroupRoomOperationID, roomID: RoomID, policy: V2GroupAudienceImportPolicy, now: Date) async throws`
- `func discardFrozen(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws`
- `func cancel(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws`
- `func purgeExpired(now: Date, limit: Int) async throws -> Int`
- `func recoverableFinalizing(now: Date, staleAfter: TimeInterval, limit: Int) async throws -> [V2GroupAudienceRecoveryCandidate]`
## V2GroupCapabilitiesStore (V2GroupCapabilitiesService.swift:8)
- `func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>`
- `func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>`
- `func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>`
- `func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>`
## V2GroupEventLogStore (V2GroupEventLogService.swift:150)
- `func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage`
- `func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription`
## V2GroupInvitationStore (V2GroupInvitationService.swift:328)
- `func create(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite`
- `func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) async throws -> [V2StoredGroupInvite]`
- `func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) async throws`
- `func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) async throws -> V2GroupInvitePreviewPersistenceOutcome`
- `func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome`
- `func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) async throws -> V2GroupJoinRequestRecordPage`
- `func approve(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupJoinApprovalPersistenceOutcome`
- `func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID, now: Date) async throws -> V2GroupJoinRequestRecord`
- `func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) async throws -> V2GroupJoinDecisionPreparationOutcome`
## V2GroupInviteCreationRecoveryStoring (V2GroupInviteCreationRecoveryWorker.swift:30)
- `func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim]`
- `func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool`
## V2GroupInviteCreationResuming (V2GroupInviteCreationRecoveryWorker.swift:58)
- `func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws`
## V2GroupInviteDirectory (V2GroupInviteDirectory.swift:36)
- `func prepare(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2GroupInviteCreationIntent`
- `func finalize(_ intent: V2GroupInviteCreationIntent, now: Date) async throws`
- `func resolve(tokenDigest: Data) async throws -> V2GroupInviteLocation?`
- `func readyInvites(roomID: RoomID, inviteIDs: Set<GroupInviteID>) async throws -> Set<GroupInviteID>`
## V2GroupMessagingStore (V2GroupMessagingService.swift:26)
- `func create( command: V2CreateGroupRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, eventID: EventID, now: Date ) async throws -> V2CreateGroupRoomOutcome`
## V2ControlValidatedGroupMessagingStore (V2GroupMessagingService.swift:52)
- `func createControlValidated( command: V2CreateGroupRoomCommand, validatedMemberUserIDs: [UserID], capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, eventID: EventID, now: Date ) async throws -> V2CreateGroupRoomOutcome`
## V2StagedGroupMessagingStore (V2GroupMessagingService.swift:80)
- `func createStaged( command: V2StagedGroupRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, eventID: EventID, now: Date ) async throws -> V2CreateGroupRoomOutcome`
## V2GroupRolePolicyBaselineReading (V2GroupRolePolicyBaseline.swift:7)
- `func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline`
## V2GroupRoomCreationIntentStore (V2GroupRoomCreationIntent.swift:114)
- `func prepare( _ candidate: V2GroupRoomCreationIntent, memberUserIDs: [UserID], now: Date ) async throws -> V2PrepareGroupRoomCreationIntentOutcome`
- `func prepareStaged( _ candidate: V2GroupRoomCreationIntent, command: V2StagedGroupRoomCommand, now: Date ) async throws -> V2PrepareGroupRoomCreationIntentOutcome`
- `func memberUserIDs( for intent: V2GroupRoomCreationIntent ) async throws -> [UserID]`
- `func memberUserIDSlice( for intent: V2GroupRoomCreationIntent, afterUserID: UserID?, limit: Int ) async throws -> V2GroupRoomCreationManifestSlice`
- `func finalizeCommitted( _ intent: V2GroupRoomCreationIntent, now: Date ) async throws -> V2GroupRoomCreationIntent`
## V2ControlValidatedStagedGroupMessagingStore (V2GroupRoomCreationManifest.swift:98)
- `func stageControlValidatedAudience( intent: V2GroupRoomCreationIntent, page: V2GroupRoomCreationManifestPage, now: Date ) async throws`
- `func createControlValidatedStaged( command: V2StagedGroupRoomCommand, intent: V2GroupRoomCreationIntent, capacityProfile: V2CapacityProfile, now: Date ) async throws -> V2CreateGroupRoomOutcome`
## V2MediaDownloadTargetResolving (V2MediaEdgeDownloadService.swift:8)
- `func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2MediaProviderObjectTarget`
## V2MediaDownloadSessionStore (V2MediaProviderSessionService.swift:74)
- `func claimDownload( requesterUserID: UserID, deviceID: DeviceID, downloadSessionID: MediaDownloadSessionID, now: Date, leaseDuration: TimeInterval ) async throws -> V2ClaimedMediaDownload`
- `func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws`
- `func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws`
## V2MediaStore (V2MediaService.swift:7)
- `func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt: Date, now: Date) async throws -> V2MediaUploadGrant`
- `func requestDownload(requesterUserID: UserID, deviceID: DeviceID, mediaID: MediaID, expiresAt: Date, now: Date) async throws -> V2MediaDownloadGrant`
- `func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws`
- `func uploadStatus(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws -> V2MediaObjectState`
- `func recordScanResult(mediaID: MediaID, passed: Bool, now: Date) async throws`
- `func assertAvailableForReference(ownerUserID: UserID, mediaIDs: [MediaID], now: Date) async throws`
## V2MessageEditStore (V2MessageEditService.swift:55)
- `func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageEditOutcome`
## V2MessageReactionStore (V2MessageReactionService.swift:54)
- `func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionOutcome`
## V2MessageWithdrawalStore (V2MessageWithdrawalService.swift:56)
- `func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome`
## V2ModerationStore (V2ModerationService.swift:141)
- `func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome`
## V2TrustedSafetyModerationStore (V2ModerationService.swift:241)
- `func applyTrustedSafety(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome`
## V2OwnerValidatedForwardMessageWriteStore (V2OwnerValidatedForwardMessages.swift:20)
- `func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID, sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome`
## V2OwnerValidatedGroupCapabilitiesStore (V2OwnerValidatedGroupCapabilitiesStore.swift:8)
- `func setPinnedMessageOwnerValidated(actorUserID: UserID, command: V2PinnedMessageCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>`
- `func setAnnouncementOwnerValidated(actorUserID: UserID, command: V2GroupAnnouncementCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>`
- `func setRolePermissionsOwnerValidated(actorUserID: UserID, command: V2GroupRolePermissionsCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>`
- `func changeMemberRoleOwnerValidated(actorUserID: UserID, command: V2GroupMemberRoleCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>`
## V2OwnerValidatedModerationStore (V2OwnerValidatedModerationStore.swift:8)
- `func applyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome`
- `func applyTrustedSafetyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome`
## V2OwnerValidatedReadReceiptStore (V2OwnerValidatedReadReceiptStore.swift:24)
- `func recordOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2ReadReceiptOutcome`
- `func recordGroupOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2GroupReadReceiptRecordingAttempt`
- `func recordGroupsOwnerValidated(_ requests: [V2OwnerValidatedReadReceiptRequest]) async throws -> [V2GroupReadReceiptBatchResult]`
- `func readerCandidatesOwnerValidated(roomID: RoomID, messageID: MessageID, actorUserID: UserID, ownerRoute: V2RoomShardRoute, cursor: String?, pageSize: Int) async throws -> V2GroupReadReceiptReaderCandidatePage`
## V2OwnerValidatedRoomWriteStore (V2OwnerValidatedRoomWriteStore.swift:27)
- `func acceptOwnerValidated( request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute ) async throws -> V2SendMessageOutcome`
- `func acceptAtomicallyOwnerValidated( requests: [V2OwnerValidatedRoomWriteRequest] ) async throws -> [V2SendMessageOutcome]`
## V2ProfilePresentationManaging (V2ProfilePresentationService.swift:7)
- `func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage`
- `func updateContactAlias(ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID, expectedRevision: V2ProfileRevision?, remarkName: String?) async throws -> V2ContactAlias`
- `func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage`
- `func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?, nickname: String?) async throws -> V2GroupMemberPresentation`
## V2ReadReceiptStore (V2ReadReceiptService.swift:45)
- `func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome`
- `func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome`
- `func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage`
## V2ReadReceiptBatchStore (V2ReadReceiptService.swift:110)
- `func recordBatch( _ requests: [V2ReadReceiptRecordRequest] ) async throws -> [V2ReadReceiptRecordResult]`
## V2GroupReadReceiptRecordingStore (V2ReadReceiptService.swift:125)
- `func recordGroup( command: V2RecordReadReceiptCommand, now: Date ) async throws -> V2GroupReadReceiptRecordingAttempt`
## V2GroupReadReceiptBatchRecordingStore (V2ReadReceiptService.swift:148)
- `func recordGroups( _ requests: [V2ReadReceiptRecordRequest] ) async throws -> [V2GroupReadReceiptBatchResult]`
## V2GroupReadReceiptReaderCandidateStore (V2ReadReceiptService.swift:251)
- `func readerCandidates( roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int ) async throws -> V2GroupReadReceiptReaderCandidatePage`
## V2ReadReceiptReaderVisibilityStore (V2ReadReceiptService.swift:274)
- `func visibleReaderIdentities( actorUserID: UserID, candidateUserIDs: [UserID] ) async throws -> [UserID: V2PublicIdentity]`
## V2RoomLogRetentionStore (V2RoomLogRetention.swift:40)
- `func trimRoomLogs( mode: V2RoomLogRetentionMode, window: TimeInterval, now: Date, limit: Int ) async throws -> V2RoomLogTrimReport`
## V2RoomMembershipDirectoryStore (V2RoomMembershipDirectoryService.swift:103)
- `func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage`
## V2RoomMembershipStore (V2RoomMembershipService.swift:61)
- `func change( command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date ) async throws -> V2RoomMembershipChangeOutcome`
## V2RoomRecoveryCommandHandling (V2RoomRecoveryCommandService.swift:6)
- `func list(_ request: IMV2UserRoomDirectoryList, actorUserID: UserID) async throws -> IMV2Envelope`
- `func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope`
- `func batch(_ request: IMV2RoomSyncStateBatch, actorUserID: UserID) async throws -> IMV2Envelope`
## V2RoomStateReading (V2RoomRecoveryReading.swift:17)
- `func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult]`
## V2UserRoomDirectoryReading (V2RoomRecoveryReading.swift:45)
- `func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice`
## V2ControlValidatedRoomMembershipStore (V2RoutedRoomMutationStores.swift:56)
- `func changeControlValidated( command: V2ChangeRoomMembershipCommand, ownerRoute: V2RoomShardRoute, identitySnapshot: V2MembershipIdentitySnapshot, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date ) async throws -> V2RoomMembershipChangeOutcome`
## V2RoomWriteStore (V2SendMessageService.swift:147)
- `func accept( command: consuming V2SendMessageCommand, capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIdentifiers, now: Date ) async throws -> V2SendMessageOutcome`
## V2AtomicRoomWriteBatchStore (V2SendMessageService.swift:202)
- `func atomicBatchEligibility( requests: [V2RoomWriteRequest] ) async -> [Bool]`
- `func atomicBatchPartitions( requests: [V2RoomWriteRequest] ) async -> [V2AtomicRoomWriteBatchPartition?]`
- `func atomicBatchSupportsRepeatedRooms( in partition: V2AtomicRoomWriteBatchPartition ) async -> Bool`
- `func acceptAtomically( requests: [V2RoomWriteRequest] ) async throws -> [V2SendMessageOutcome]`
## V2SpecialAccountMessagingStore (V2SpecialAccountMessagingService.swift:110)
- `func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount?`
- `func authorizeOutbound(account: V2ResolvedSpecialAccount, roomID: RoomID, customerUserID: UserID) async throws`
- `func record( request: V2TrustedSpecialAccountMessage, account: V2ResolvedSpecialAccount, roomID: RoomID, outcome: V2SendMessageOutcome, now: Date ) async throws`

## Existing façade and worker signatures that add IDs, time or coordination

All are in target `IMV2Server`; DTO target and Codable details are in the type register. Generated `EventID`/clock/capacity arguments in a store signature are **local execution inputs**, not independently supplied by an untrusted wire caller.

| Source | Exact existing method |
| --- | --- |
| `V2SendMessageService.swift:672` | `public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome` |
| `V2MessageEditService.swift:111` | `public func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome` |
| `V2MessageWithdrawalService.swift:113` | `public func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome` |
| `V2MessageReactionService.swift:108` | `public func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome` |
| `V2RoomMembershipService.swift:126` | `public func change(_ request: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome` |
| `V2ModerationService.swift:297` | `public func apply(_ request: V2AuthenticatedModeration) async throws -> V2ModerationOutcome` |
| `V2ModerationService.swift:345,361` | `public func apply(_ request: V2TrustedSafetyRoomControl) async throws -> V2ModerationOutcome`; `public func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome` |
| `V2ReadReceiptService.swift:331` | `public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome` |
| `V2DirectMessagingService.swift:236` | `public func open(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome` |
| `V2GroupMessagingService.swift:232,291` | `public func create(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, initialMemberUserIDs: [UserID]) async throws -> V2CreateGroupRoomOutcome`; `public func createStaged(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, stagedMemberCount: Int) async throws -> V2CreateGroupRoomOutcome` |
| `V2GroupAudienceImportService.swift:165–225` | `public func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String) async throws -> V2GroupAudienceDraft`; `public func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2GroupAudienceDraft`; `public func finalize(actorUserID: UserID, operationID: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome`; `public func cancel(actorUserID: UserID, operationID: GroupRoomOperationID) async throws` |
| `V2GroupInvitationService.swift:365–435` | `public func create(_ request: V2CreateGroupInviteRequest) async throws -> V2GroupInviteLink`; `public func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID) async throws`; `public func preview(secret: V2GroupInviteSecret, applicantUserID: UserID) async throws -> V2GroupInvitePreview?`; `public func submit(_ request: V2SubmitGroupJoinRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome`; `public func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID) async throws -> V2GroupJoinRequest`; `public func decide(_ input: V2DecideGroupJoinRequest) async throws -> V2GroupJoinDecisionOutcome` |
| `V2MediaProviderSessionService.swift:157` | `public func exchangeDownload(actorUserID: UserID, deviceID: DeviceID, downloadSessionID: MediaDownloadSessionID) async throws -> V2MediaProviderObjectTarget` |
| `V2ForwardDeliveryWorker.swift:94` | `public func runOnce(sourceShardID: String, limit: Int) async throws -> V2ForwardDeliveryReport` |
| `V2ForwardMediaImportWorker.swift:131` | `public func runOnce(exportID: UUID) async throws -> V2ForwardMediaImportOutcome` |
| `V2GroupInviteCreationRecoveryWorker.swift:113` | `public func runOnce(limit: Int = 8) async throws -> V2GroupInviteCreationRecoveryReport` |
| `V2GroupJoinQuotaRecoveryWorker.swift:24` | `public func runOnce(limit: Int = 8) async throws -> V2GroupJoinQuotaRecoveryReport` |
| `V2ContentReviewWorker.swift:244` | `public func runOnce(limit: Int) async throws -> V2ContentReviewReport` |
| `V2RoomLogRetention.swift:262` | `public func runOnce(limit: Int) async throws -> V2RoomLogTrimReport` |
| `V2ControlPlaneHousekeepingWorker.swift:102` | `public func runOnce(limit: Int) async throws -> V2ControlPlaneHousekeepingReport` |
