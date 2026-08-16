import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 gateway domain command handler")
struct V2GatewayDomainCommandHandlerTests {
    @Test("send validates client data and takes the actor exclusively from the session")
    func sendValidationAndAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = InMemoryV2RoomWriteStore(
            seed: [(fixture.roomState, fixture.shardState)],
            authorizedActors: [fixture.userID],
            mediaPresentationResolver: { media in
                try media.map {
                    try .init(mediaID: $0.mediaID, kind: .file, contentType: "application/octet-stream", byteCount: 1)
                }
            }
        )
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: store),
            sync: fixture.syncService(),
            telemetry: telemetry,
            now: { fixture.now }
        )

        var malformed = IMV2Envelope()
        malformed.sendMessage = .init()
        malformed.sendMessage.roomID = "not-a-uuid"
        malformed.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        malformed.sendMessage.content = .init()
        malformed.sendMessage.content.text = "hello"
        #expect(try await handler.handle(envelope: malformed, identity: fixture.identity).error.code == "INVALID_ARGUMENT")

        var blank = IMV2Envelope()
        blank.sendMessage = .init()
        blank.sendMessage.roomID = fixture.roomID.rawValue
        blank.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        blank.sendMessage.content = .init()
        blank.sendMessage.content.text = ""
        #expect(try await handler.handle(envelope: blank, identity: fixture.identity).error.code == "INVALID_ARGUMENT")

        var valid = IMV2Envelope()
        valid.sendMessage = .init()
        valid.sendMessage.roomID = fixture.roomID.rawValue
        valid.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        valid.sendMessage.content = .init()
        valid.sendMessage.content.text = "hello"
        let response = try await handler.handle(envelope: valid, identity: fixture.identity)
        #expect(response.messageAccepted.roomID == fixture.roomID.rawValue)
        let mediaID = "00000000-0000-0000-0000-000000000025"
        var attachmentOnly = IMV2Envelope()
        attachmentOnly.sendMessage = .init()
        attachmentOnly.sendMessage.roomID = fixture.roomID.rawValue
        attachmentOnly.sendMessage.clientMessageID = "00000000-0000-0000-0000-000000000026"
        attachmentOnly.sendMessage.content = .init()
        attachmentOnly.sendMessage.content.mediaIds = [mediaID]
        let attachmentResponse = try await handler.handle(envelope: attachmentOnly, identity: fixture.identity)
        #expect(attachmentResponse.messageAccepted.mediaIds == [mediaID])
        #expect(attachmentResponse.messageAccepted.mediaPresentations.map(\.mediaID) == [mediaID])
        let state = try #require(await store.state(for: fixture.roomID))
        let accepted = try #require(state.0.acceptedCommands.values.first)
        #expect(accepted.senderUserID == fixture.identity.userID)

        let events = await telemetry.events()
        #expect(events.count == 4)
        guard case .gatewayCommand(_, .sendMessage, .rejected, .invalidArgument, 0) = events[0] else {
            Issue.record("expected a privacy-safe invalid-argument metric")
            return
        }
        guard case .gatewayCommand(_, .sendMessage, .accepted, nil, 0) = events[2] else {
            Issue.record("expected an accepted command metric")
            return
        }
    }

    @Test("an accepted group message emits only a best-effort foreground watermark hint")
    func acceptedGroupMessagePublishesForegroundHint() async throws {
        let fixture = try GatewayDomainFixture()
        let accepted = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000040"),
            roomID: fixture.roomID,
            roomSequence: 9,
            senderUserID: fixture.userID,
            clientMessageID: fixture.clientMessageID,
            text: "hello",
            mediaPresentations: [],
            groupDeliveryMode: .standardFanout,
            createdAt: fixture.now
        )
        let hints = GatewayForegroundHintRecorder()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .accepted(accepted))),
            foregroundGroupEventHints: hints,
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.messageAccepted.roomSequence == 9)
        #expect(await hints.values() == [.init(roomID: fixture.roomID, highWatermark: 9)])
    }

    @Test("invalid sync state is returned as a stable protocol error")
    func syncStateErrors() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            sync: .init(store: GatewayRejectingSyncStore())
        )
        var pull = IMV2Envelope()
        pull.syncPull = .init()
        pull.syncPull.syncToken = "expired-token"
        #expect(try await handler.handle(envelope: pull, identity: fixture.identity).error.code == "SYNC_TOKEN_INVALID")

        var acknowledge = IMV2Envelope()
        acknowledge.syncAck = .init()
        acknowledge.syncAck.generation = 1
        acknowledge.syncAck.highestContiguousSequence = 4
        acknowledge.syncAck.syncReceipt = "expired-receipt"
        #expect(try await handler.handle(envelope: acknowledge, identity: fixture.identity).error.code == "SYNC_RECEIPT_INVALID")
    }

    @Test("membership change takes the actor exclusively from the authenticated session")
    func membershipChangeUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let membershipStore = GatewayMembershipStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membership: .init(store: membershipStore, capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope()
        request.changeRoomMembership = .init()
        request.changeRoomMembership.roomID = fixture.roomID.rawValue
        request.changeRoomMembership.operationID = "00000000-0000-0000-0000-000000000016"
        request.changeRoomMembership.targetUserID = "00000000-0000-0000-0000-000000000017"
        request.changeRoomMembership.action = .add
        request.changeRoomMembership.expectedMembershipRevision = 4

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.membershipChanged.roomID == fixture.roomID.rawValue)
        #expect(response.membershipChanged.action == .add)
        #expect(await membershipStore.actor() == fixture.userID)
    }

    @Test("staged group creation binds every page and finalization to the authenticated owner")
    func stagedGroupCreationUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let groupStore = GatewayGroupStore()
        let audienceStore = GatewayAudienceImportStore()
        let groupMessaging = try V2GroupMessagingService(
            store: groupStore,
            capacityProfile: .init(id: "standard", limits: fixture.profile),
            roomShardID: "rooms-primary",
            now: { fixture.now }
        )
        let audienceImports = V2GroupAudienceImportService(
            store: audienceStore,
            groupMessaging: groupMessaging,
            now: { fixture.now }
        )
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupAudienceImports: audienceImports,
            sync: fixture.syncService()
        )
        let operationID = "00000000-0000-0000-0000-000000000036"
        let memberID = "00000000-0000-0000-0000-000000000037"

        var begin = IMV2Envelope(); begin.beginGroupRoomCreation = .init()
        begin.beginGroupRoomCreation.operationID = operationID
        begin.beginGroupRoomCreation.title = " 分页项目群 "
        let prepared = try await handler.handle(envelope: begin, identity: fixture.identity)
        #expect(prepared.groupRoomCreationPrepared.title == "分页项目群")
        #expect(prepared.groupRoomCreationPrepared.stagedMemberCount == 0)

        var append = IMV2Envelope(); append.appendGroupRoomCreationMembers = .init()
        append.appendGroupRoomCreationMembers.operationID = operationID
        append.appendGroupRoomCreationMembers.memberUserIds = [memberID]
        let appended = try await handler.handle(envelope: append, identity: fixture.identity)
        #expect(appended.groupRoomCreationMembersAppended.stagedMemberCount == 1)

        var finalize = IMV2Envelope(); finalize.finalizeGroupRoomCreation = .init()
        finalize.finalizeGroupRoomCreation.operationID = operationID
        let created = try await handler.handle(envelope: finalize, identity: fixture.identity)
        #expect(created.groupRoomCreated.memberCount == 2)
        #expect(created.groupRoomCreated.memberUserIds.isEmpty)
        #expect(await groupStore.actor() == fixture.userID)
        #expect(await groupStore.members() == [fixture.userID, try UserID(memberID)])
        #expect(await audienceStore.actor() == fixture.userID)
    }

    @Test("stalled finalizing draft is replayed with its original operation identity")
    func finalizingDraftRecoveryReplaysTheOriginalOperation() async throws {
        let fixture = try GatewayDomainFixture()
        let groupStore = GatewayGroupStore()
        let audienceStore = GatewayAudienceImportStore()
        let groupMessaging = try V2GroupMessagingService(
            store: groupStore,
            capacityProfile: .init(id: "standard", limits: fixture.profile),
            roomShardID: "rooms-primary",
            now: { fixture.now }
        )
        let imports = V2GroupAudienceImportService(
            store: audienceStore,
            groupMessaging: groupMessaging,
            policy: .init(maximumStagedMembersPerActor: fixture.profile.maxEligibleMembers, finalizingRecoveryInterval: 30),
            now: { fixture.now }
        )
        let operationID = try GroupRoomOperationID("00000000-0000-0000-0000-000000000038")
        let member = try UserID("00000000-0000-0000-0000-000000000039")
        _ = try await imports.begin(actorUserID: fixture.userID, operationID: operationID, title: "恢复群")
        _ = try await imports.append(actorUserID: fixture.userID, operationID: operationID, memberUserIDs: [member])
        await audienceStore.setRecoveryCandidates([.init(actorUserID: fixture.userID, operationID: operationID)])

        #expect(try await imports.recoverFinalizing(limit: 1) == .init(claimedCount: 1, recoveredCount: 1, failedCount: 0))
        #expect(await groupStore.actor() == fixture.userID)
        #expect(await groupStore.members() == [fixture.userID, member])
        #expect(await audienceStore.completedOperationIDs() == [operationID])
    }

    @Test("one corrupt recovery candidate does not strand later claimed candidates")
    func recoveryContinuesAfterAnIndividualCandidateFails() async throws {
        let fixture = try GatewayDomainFixture()
        let groupStore = GatewayGroupStore()
        let audienceStore = GatewayAudienceImportStore()
        let groupMessaging = try V2GroupMessagingService(
            store: groupStore,
            capacityProfile: .init(id: "standard", limits: fixture.profile),
            roomShardID: "rooms-primary",
            now: { fixture.now }
        )
        let imports = V2GroupAudienceImportService(
            store: audienceStore,
            groupMessaging: groupMessaging,
            policy: .init(maximumStagedMembersPerActor: fixture.profile.maxEligibleMembers, finalizingRecoveryInterval: 30),
            now: { fixture.now }
        )
        let goodOperation = try GroupRoomOperationID("00000000-0000-0000-0000-000000000040")
        let badOperation = try GroupRoomOperationID("00000000-0000-0000-0000-000000000041")
        _ = try await imports.begin(actorUserID: fixture.userID, operationID: goodOperation, title: "可恢复群")
        await audienceStore.setRecoveryCandidates([
            .init(actorUserID: fixture.userID, operationID: badOperation),
            .init(actorUserID: fixture.userID, operationID: goodOperation)
        ])
        await audienceStore.setFailingRecoveryOperationIDs([badOperation])

        #expect(try await imports.recoverFinalizing(limit: 2) == .init(claimedCount: 2, recoveredCount: 1, failedCount: 1))
        #expect(await audienceStore.completedOperationIDs() == [goodOperation])
    }

    @Test("frozen group creation cancellation has a distinct stable protocol code")
    func frozenGroupCreationCancellationUsesDedicatedProtocolCode() async throws {
        let fixture = try GatewayDomainFixture()
        let audienceStore = GatewayAudienceImportStore()
        await audienceStore.setCancellationFrozen(true)
        let groupMessaging = try V2GroupMessagingService(
            store: GatewayGroupStore(),
            capacityProfile: .init(id: "standard", limits: fixture.profile),
            roomShardID: "rooms-primary",
            now: { fixture.now }
        )
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupAudienceImports: .init(store: audienceStore, groupMessaging: groupMessaging, now: { fixture.now }),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.cancelGroupRoomCreation = .init()
        request.cancelGroupRoomCreation.operationID = "00000000-0000-0000-0000-000000000042"

        #expect(try await handler.handle(envelope: request, identity: fixture.identity).error.code == "GROUP_CREATION_FROZEN")
    }

    @Test("Hybrid room subscription verifies the session actor and returns only its waterline")
    func groupEventSubscriptionUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayGroupEventLogStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupEventLog: .init(store: store),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = fixture.roomID.rawValue
        request.groupEventSubscribe.afterRoomSequence = 77

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.groupEventSubscribed.roomID == fixture.roomID.rawValue)
        #expect(response.groupEventSubscribed.highWatermark == 91)
        #expect(await store.actor() == fixture.userID)
    }

    @Test("member directory takes its requester only from the authenticated session")
    func membershipDirectoryUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayMembershipDirectoryStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membershipDirectory: .init(store: store),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = fixture.roomID.rawValue
        request.listRoomMembers.pageSize = 100

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.roomMembersPage.roomID == fixture.roomID.rawValue)
        #expect(response.roomMembersPage.actorRole == .owner)
        #expect(response.roomMembersPage.members.count == 1)
        #expect(response.roomMembersPage.members.first?.publicHandle == "owner_1")
        #expect(response.roomMembersPage.members.first?.displayName == "群主")
        #expect(response.roomMembersPage.members.first?.accountKind == "regular")
        #expect(await store.actor() == fixture.userID)
    }

    @Test("relationship and block commands use only the authenticated actor")
    func socialCommandsUseAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewaySocialRelationshipStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            socialRelationships: .init(store: store, now: { fixture.now }),
            sync: fixture.syncService()
        )
        var relationship = IMV2Envelope(); relationship.changeRelationship = .init()
        relationship.changeRelationship.operationID = "00000000-0000-0000-0000-000000000018"
        relationship.changeRelationship.targetUserID = "00000000-0000-0000-0000-000000000019"
        relationship.changeRelationship.action = .request
        let relationshipResponse = try await handler.handle(envelope: relationship, identity: fixture.identity)
        #expect(relationshipResponse.relationshipChanged.resultingState == .pending)

        var block = IMV2Envelope(); block.changeUserBlock = .init()
        block.changeUserBlock.operationID = "00000000-0000-0000-0000-000000000020"
        block.changeUserBlock.targetUserID = "00000000-0000-0000-0000-000000000019"
        block.changeUserBlock.action = .block
        let blockResponse = try await handler.handle(envelope: block, identity: fixture.identity)
        #expect(blockResponse.userBlockChanged.isBlocked)
        #expect(await store.actors() == [fixture.userID, fixture.userID])
    }

    @Test("moderation redaction takes its actor exclusively from the session")
    func moderationUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayModerationStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            moderation: .init(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.moderateMessage = .init()
        request.moderateMessage.roomID = fixture.roomID.rawValue
        request.moderateMessage.operationID = "00000000-0000-0000-0000-000000000027"
        request.moderateMessage.messageID = "00000000-0000-0000-0000-000000000028"
        request.moderateMessage.reasonCode = "abuse_spam"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.messageRedacted.roomID == fixture.roomID.rawValue)
        #expect(response.messageRedacted.messageRevision == 2)
        #expect(await store.actor() == fixture.userID)
    }

    @Test("member mute takes its actor exclusively from the session")
    func memberMuteUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayModerationStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            moderation: .init(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.muteMember = .init()
        request.muteMember.roomID = fixture.roomID.rawValue
        request.muteMember.operationID = "00000000-0000-0000-0000-000000000029"
        request.muteMember.targetUserID = "00000000-0000-0000-0000-000000000030"
        request.muteMember.muteUntilMs = Int64(fixture.now.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        request.muteMember.reasonCode = "abuse_spam"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.memberMuted.targetUserID == request.muteMember.targetUserID)
        #expect(response.memberMuted.muteUntilMs == request.muteMember.muteUntilMs)
        #expect(await store.actor() == fixture.userID)
    }

    @Test("audit member removal takes its actor exclusively from the session")
    func moderatedMemberRemovalUsesAuthenticatedActor() async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayModerationStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            moderation: .init(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.moderateMemberRemoval = .init()
        request.moderateMemberRemoval.roomID = fixture.roomID.rawValue
        request.moderateMemberRemoval.operationID = "00000000-0000-0000-0000-000000000031"
        request.moderateMemberRemoval.targetUserID = "00000000-0000-0000-0000-000000000032"
        request.moderateMemberRemoval.reasonCode = "abuse_spam"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.memberRemovedByModerator.targetUserID == request.moderateMemberRemoval.targetUserID)
        #expect(response.memberRemovedByModerator.membershipRevision == 4)
        #expect(await store.actor() == fixture.userID)
    }
}

private struct GatewayDomainFixture: Sendable {
    let roomID = try! RoomID("00000000-0000-0000-0000-000000000011")
    let userID = try! UserID("00000000-0000-0000-0000-000000000012")
    let deviceID = try! DeviceID("00000000-0000-0000-0000-000000000013")
    let clientMessageID = try! ClientMessageID("00000000-0000-0000-0000-000000000014")
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let profile: RoomCapacityProfile
    let roomState: V2RoomCommandState
    let shardState: ShardAdmissionState

    init() throws {
        profile = try .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 10, maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 7)
        roomState = try .init(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), outstandingFanoutUnits: 0, outstandingPlans: 0))
        shardState = try .init(lease: .init(id: try .init("00000000-0000-0000-0000-000000000015"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10), outstandingFanoutUnits: 0, outstandingPlans: 0)
    }

    var identity: V2AuthenticatedConnection { .init(userID: userID, deviceID: deviceID, capabilityProfile: "base") }

    func sendService(store: any V2RoomWriteStore) -> V2SendMessageService {
        V2SendMessageService(store: store, capacityProfile: try! .init(id: "standard", limits: profile), limits: try! .init(maxUTF8Bytes: 16), now: { now })
    }

    func syncService() -> V2SyncService { .init(store: GatewayRejectingSyncStore()) }
}

private struct GatewayRejectingSyncStore: V2SyncStore {
    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, now _: Date) async throws -> V2SyncPullResult {
        throw V2SyncStoreError.invalidOrExpiredSyncToken
    }

    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws {
        throw V2SyncStoreError.invalidOrExpiredSyncReceipt
    }

    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) async throws -> V2SnapshotManifest {
        throw V2SyncStoreError.snapshotExpiredOrInvalid
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) async throws -> V2SnapshotPage {
        throw V2SyncStoreError.snapshotExpiredOrInvalid
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws {}
}

private struct GatewayAcceptedMessageStore: V2RoomWriteStore {
    let outcome: V2SendMessageOutcome

    func accept(
        command _: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers _: V2AcceptanceIdentifiers,
        now _: Date
    ) async throws -> V2SendMessageOutcome {
        outcome
    }
}

private actor GatewayForegroundHintRecorder: V2ForegroundGroupEventHintPublishing {
    private var hints: [V2GroupEventWake] = []

    func publishForegroundHint(_ hint: V2GroupEventWake) {
        hints.append(hint)
    }

    func values() -> [V2GroupEventWake] { hints }
}

private actor GatewayMembershipStore: V2RoomMembershipStore {
    private var capturedActor: UserID?

    func change(command: V2ChangeRoomMembershipCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        capturedActor = command.actorUserID
        return .changed(.init(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action, membershipRevision: command.expectedMembershipRevision + 1, roomSequence: 1, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }

    func actor() -> UserID? { capturedActor }
}

private actor GatewayMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private var capturedActor: UserID?

    func list(_ request: V2RoomMembershipDirectoryRequest) throws -> V2RoomMembershipDirectoryPage {
        capturedActor = request.actorUserID
        return .init(
            roomID: request.roomID,
            membershipRevision: 4,
            actorRole: .owner,
            entries: [
                .init(
                    userID: request.actorUserID,
                    role: .owner,
                    publicIdentity: try! .init(userID: request.actorUserID, handle: .init("owner_1"), displayName: "群主", accountKind: .regular)
                )
            ],
            nextCursor: nil
        )
    }

    func actor() -> UserID? { capturedActor }
}

private actor GatewayGroupStore: V2GroupMessagingStore {
    private var capturedActor: UserID?
    private var capturedMembers: [UserID] = []

    func create(command: V2CreateGroupRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID _: String, roomID: RoomID, eventID _: EventID, planID _: FanoutPlanID, now: Date) -> V2CreateGroupRoomOutcome {
        capturedActor = command.actorUserID
        capturedMembers = command.allMemberUserIDs
        return .created(.init(roomID: roomID, ownerUserID: command.actorUserID, title: command.title, deliveryMode: command.deliveryMode, memberUserIDs: command.allMemberUserIDs, createdAt: now))
    }

    func actor() -> UserID? { capturedActor }
    func members() -> [UserID] { capturedMembers }
}

private actor GatewayAudienceImportStore: V2GroupAudienceImportStore {
    private var capturedActor: UserID?
    private var title: String?
    private var members: [UserID] = []
    private var recoveryCandidates: [V2GroupAudienceRecoveryCandidate] = []
    private var completedOperationIDsValue: [GroupRoomOperationID] = []
    private var failingRecoveryOperationIDs: Set<GroupRoomOperationID> = []
    private var cancellationFrozen = false

    func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy _: V2GroupAudienceImportPolicy, now _: Date) throws -> V2GroupAudienceDraft {
        capturedActor = actorUserID
        if let existingTitle = self.title {
            guard existingTitle == title else { throw V2GroupAudienceImportError.idempotencyConflict }
        } else {
            self.title = title
        }
        return .init(operationID: operationID, title: title, stagedMemberCount: members.count)
    }

    func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy _: V2GroupAudienceImportPolicy, now _: Date) throws -> V2GroupAudienceDraft {
        capturedActor = actorUserID
        guard let title else { throw V2GroupAudienceImportError.missingDraft }
        members = Array(Set(members).union(memberUserIDs)).sorted()
        guard members.count <= maximumMembers else { throw V2GroupAudienceImportError.memberLimitReached }
        return .init(operationID: operationID, title: title, stagedMemberCount: members.count)
    }

    func freeze(actorUserID: UserID, operationID: GroupRoomOperationID, policy _: V2GroupAudienceImportPolicy, now _: Date) throws -> V2GroupAudienceImport {
        capturedActor = actorUserID
        if failingRecoveryOperationIDs.contains(operationID) {
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        guard let title else { throw V2GroupAudienceImportError.missingDraft }
        return try .init(actorUserID: actorUserID, operationID: operationID, title: title, memberUserIDs: members)
    }

    func complete(actorUserID: UserID, operationID: GroupRoomOperationID, roomID _: RoomID, policy _: V2GroupAudienceImportPolicy, now _: Date) {
        capturedActor = actorUserID
        completedOperationIDsValue.append(operationID)
    }

    func discardFrozen(actorUserID: UserID, operationID _: GroupRoomOperationID, now _: Date) {
        capturedActor = actorUserID
        title = nil
        members = []
    }

    func cancel(actorUserID: UserID, operationID _: GroupRoomOperationID, now _: Date) throws {
        capturedActor = actorUserID
        if cancellationFrozen { throw V2GroupAudienceImportError.draftFrozen }
        title = nil
        members = []
    }

    func purgeExpired(now _: Date, limit _: Int) -> Int { 0 }
    func recoverableFinalizing(now _: Date, staleAfter _: TimeInterval, limit: Int) -> [V2GroupAudienceRecoveryCandidate] { Array(recoveryCandidates.prefix(limit)) }

    func actor() -> UserID? { capturedActor }
    func setRecoveryCandidates(_ candidates: [V2GroupAudienceRecoveryCandidate]) { recoveryCandidates = candidates }
    func setFailingRecoveryOperationIDs(_ operationIDs: Set<GroupRoomOperationID>) { failingRecoveryOperationIDs = operationIDs }
    func setCancellationFrozen(_ frozen: Bool) { cancellationFrozen = frozen }
    func completedOperationIDs() -> [GroupRoomOperationID] { completedOperationIDsValue }
}

private actor GatewayGroupEventLogStore: V2GroupEventLogStore {
    private var capturedActor: UserID?

    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) throws -> V2GroupEventLogPage {
        .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: false)
    }

    func subscribe(roomID: RoomID, actorUserID: UserID) throws -> V2GroupEventSubscription {
        capturedActor = actorUserID
        return .init(roomID: roomID, highWatermark: 91)
    }

    func actor() -> UserID? { capturedActor }
}

private actor GatewayModerationStore: V2ModerationStore {
    private var capturedActor: UserID?
    func actor() -> UserID? { capturedActor }
    func apply(command: V2ModerationCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2ModerationOutcome {
        capturedActor = command.actorUserID
        return .applied(.init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: command.targetUserID, messageID: command.messageID, messageRevision: command.action == .redactMessage ? 2 : nil, membershipRevision: command.action == .removeMember ? 4 : nil, muteUntil: command.muteUntil, roomSequence: 3, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
}

private actor GatewaySocialRelationshipStore: V2SocialRelationshipStore {
    private var capturedActors: [UserID] = []
    func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) throws -> V2RelationshipOutcome {
        capturedActors.append(command.actorUserID)
        return .changed(.init(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, resultingState: .pending, updatedAt: now))
    }
    func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) throws -> V2UserBlockOutcome {
        capturedActors.append(command.actorUserID)
        return .changed(.init(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, isBlocked: command.action == .block, updatedAt: now))
    }
    func actors() -> [UserID] { capturedActors }
}
