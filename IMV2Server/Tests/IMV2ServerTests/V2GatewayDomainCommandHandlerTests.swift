import AsyncKit
import Foundation
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("V2 gateway domain command handler")
struct V2GatewayDomainCommandHandlerTests {
    @Test("durable authorization errors remain request-scoped", arguments:
        ["owner", "drain", "aborted", "conflict", "corrupt"])
    func directAuthorizationErrorMapping(kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1), beforeReturn: {
            switch kind {
            case "owner": throw V2DirectAuthorizationCoordinationError.ownerUnavailable
            case "drain": throw V2DirectAuthorizationCoordinationError.revocationIncomplete
            case "aborted": throw V2DirectAuthorizationReceiptError.attemptAborted
            case "conflict": throw V2DirectAuthorizationIntentError.identityConflict
            default: throw V2DirectAuthorizationIntentError.corruptPersistence
            }
        })
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: store), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "authorization"
        for _ in 0..<2 {
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == (kind == "conflict" ? "IDEMPOTENCY_CONFLICT" : "UNAVAILABLE"))
            #expect(response.error.retryable == (kind != "conflict"))
        }
    }

    @Test("Account coverage start uses the authenticated origin connection", arguments: [false, true])
    func accountCoverageStart(hasOrigin: Bool) async throws {
        let fixture = try GatewayDomainFixture(), probe = GatewayAccountStartProbe()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            accountChanges: probe, sync: fixture.syncService())
        let connection = UUID()
        var request = IMV2Envelope(); request.accountRoomChangesStart = .init()
        let response = try await handler.handle(envelope: request, identity: fixture.identity,
            originatingConnectionID: hasOrigin ? connection : nil)
        if hasOrigin {
            #expect(response.accountRoomChangesReady.connectionEpoch == probe.epoch.uuidString)
            #expect(await probe.connectionID == connection)
            #expect(await probe.userID == fixture.userID)
        } else {
            #expect(response.error.code == "UNAVAILABLE")
            #expect(await probe.connectionID == nil)
        }
    }

    @Test("Recovery reads receive the authenticated actor", arguments: [0, 1, 2])
    func recoveryAuthenticatedActor(batch: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let recovery = GatewayRecoveryProbe()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            roomRecovery: recovery, sync: fixture.syncService())
        var request = IMV2Envelope()
        if batch == 2 { request.roomLatestVisibleBatch.roomIds = [fixture.roomID.rawValue] }
        else if batch == 1 { request.roomSyncStateBatch.roomIds = [fixture.roomID.rawValue] }
        else { request.userRoomDirectoryList.pageSize = 10 }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(await recovery.actor == fixture.userID)
        if batch == 2 { #expect(response.body == .roomLatestVisibleBatchResult(.init())) }
        else if batch == 1 { #expect(response.body == .roomSyncStateBatchResult(.init())) }
        else { #expect(response.body == .userRoomDirectoryPage(.init())) }
    }

    @Test("Recovery topology errors explicitly request a fresh directory scan")
    func recoveryTopologyReset() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            roomRecovery: GatewayRecoveryProbe(failure: .topologyChanged), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.userRoomDirectoryList.pageSize = 10
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "ROOM_DIRECTORY_RESET_REQUIRED")
        #expect(response.error.retryable)
    }

    @Test("Gateway response metrics measure elapsed time despite wall-clock corrections",
          arguments: [Double(-3_600), 3_600, .nan], ["accepted", "rejected", "failed"])
    func telemetryElapsedClock(wallShift: Double, outcome: String) async throws {
        let fixture = try GatewayDomainFixture()
        let clock = V2TelemetryTestClock()
        let message = V2AcceptedMessage(messageID: .init(uuid: UUID()), roomID: fixture.roomID,
            roomSequence: 9, senderUserID: fixture.userID, clientMessageID: fixture.clientMessageID,
            text: "hello", mediaPresentations: [], createdAt: fixture.now)
        let telemetry = V2InMemoryTelemetrySink()
        let store = GatewayAcceptedMessageStore(
            outcome: outcome == "rejected" ? .rateLimited(retryAfterSeconds: 1) : .idempotent(message.receipt),
            beforeReturn: {
                clock.advance(by: .milliseconds(25), wallShift: wallShift)
                if outcome == "failed" { throw CancellationError() }
            })
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: store),
            sync: fixture.syncService(), telemetry: telemetry, now: { clock.now() },
            monotonicNow: { clock.monotonicNow() })
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        do {
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(outcome != "failed")
            if outcome == "rejected" { #expect(response.error.code == "RATE_LIMITED") }
            else { #expect(response.messageAccepted.messageID == message.messageID.rawValue) }
        } catch is CancellationError { #expect(outcome == "failed") }
        guard case .gatewayCommand(_, .sendMessage, let recordedOutcome, _, let elapsed) = await telemetry.events().first else {
            Issue.record("Missing Gateway command metric")
            return
        }
        #expect(elapsed == 25)
        #expect(recordedOutcome.rawValue == outcome)
    }

    @Test("Snapshot preparation preserves bounded retry intervals and recovers from invalid intervals")
    func snapshotPreparationRetryIntervals() async throws {
        let fixture = try GatewayDomainFixture()
        let cases: [(Double, UInt32?)] = [
            (.nan, nil), (.infinity, nil), (-.infinity, nil),
            (.greatestFiniteMagnitude, nil), (-.greatestFiniteMagnitude, nil),
            (-1, nil), (-0.1, nil), (0, 0), (0.001, 1), (0.999, 1),
            (1, 1), (1.001, 2), (2.25, 3),
            (Double(UInt32.max) - 0.25, UInt32.max), (Double(UInt32.max), UInt32.max),
            (Double(UInt32.max) + 0.25, nil)
        ]
        for (interval, expected) in cases {
            let store = GatewaySnapshotClockStore(retryAfter: interval)
            let handler = makeGatewayDomainCommandHandler(
                sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
                sync: .init(store: store, now: { fixture.now }))
            var request = IMV2Envelope()
            request.syncPull.requireSnapshot = true
            request.syncPull.maxRecords = 10
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == (expected == nil ? "UNAVAILABLE" : "RESET_PREPARING"))
            #expect(response.error.retryAfterSeconds == (expected ?? 0))
            #expect(response.error.retryable)

            await store.setRetryAfter(1.25)
            let recovered = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(recovered.error.code == "RESET_PREPARING" && recovered.error.retryable)
            #expect(recovered.error.retryAfterSeconds == 2)
            #expect(await store.calls == 2)
        }
    }

    @Test("Snapshot reset and manifest responses reject invalid expiry and preserve signed milliseconds on retry",
          arguments: [false, true], [Double.nan, .infinity, -.infinity,
              .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
              Double(Int64.max) / 1_000, -Double(Int64.max) / 500])
    func snapshotExpiryResponseBoundary(manifest: Bool, seconds: Double) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewaySnapshotClockStore(expiresAt: Date(timeIntervalSince1970: seconds))
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            sync: .init(store: store, now: { fixture.now }))
        var request = IMV2Envelope()
        if manifest {
            request.syncSnapshot.snapshotID = store.snapshotID.rawValue
            request.syncSnapshot.generation = 1
        } else {
            request.syncPull.requireSnapshot = true
            request.syncPull.maxRecords = 10
        }
        let failed = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(failed.error.code == "UNAVAILABLE" && failed.error.retryable)
        #expect(failed.error.retryAfterSeconds == 0)
        for (dateSeconds, expectedMilliseconds): (Double, Int64) in [(-1.25, -1_250), (0, 0), (1_750_000_000.125, 1_750_000_000_125)] {
            await store.setExpiry(Date(timeIntervalSince1970: dateSeconds))
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code.isEmpty)
            if manifest {
                #expect(response.snapshotManifest.snapshotID == store.snapshotID.rawValue)
                #expect(response.snapshotManifest.expiresAtMs == expectedMilliseconds)
                #expect(response.snapshotManifest.generation == 1)
                #expect(response.snapshotManifest.baseUserSyncSequence == 7)
            } else {
                #expect(response.resetRequired.snapshotID == store.snapshotID.rawValue)
                #expect(response.resetRequired.expiresAtMs == expectedMilliseconds)
                #expect(response.resetRequired.generation == 1)
                #expect(response.resetRequired.baseUserSyncSequence == 7)
            }
        }
        #expect(await store.calls == 4)
    }

    @Test("Out-of-range receipt sequences are nonretryable request errors before storage or replay",
          arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func receiptSequenceRangeIsARequestError(_ invalid: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayReadReceiptSequenceStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            readReceipt: .init(store: store, now: { fixture.now }), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.recordReadReceipt.roomID = fixture.roomID.rawValue
        request.recordReadReceipt.operationID = UUID().uuidString
        for expectedCalls in 0...1 {
            request.recordReadReceipt.readThroughRoomSequence = invalid
            let rejected = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(rejected.error.code == "INVALID_ARGUMENT" && !rejected.error.retryable)
            #expect(await store.calls == expectedCalls)
            request.recordReadReceipt.readThroughRoomSequence = UInt64(Int64.max)
            let valid = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(valid.readReceiptRecorded.readThroughRoomSequence == UInt64(Int64.max))
            #expect(valid.readReceiptRecorded.recordedAtMs == 1_750_000_000_000)
        }
        #expect(await store.calls == 2)
    }

    @Test("Domain timestamp responses reject unencodable dates and recover on retry",
          arguments: [false, true], ["edit", "withdraw", "reaction", "membership", "redact", "mute", "mute-expiry", "remove", "relationship", "block",
                                    "receipt", "receipt-preferences", "direct", "stranger", "user-add", "live-set", "live-get", "presence",
                                    "conversation", "conversation-mute", "favorite", "pinned", "announcement", "group"])
    func remainingResponseTimestampBoundaries(replay: Bool, path: String) async throws {
        let fixture = try GatewayDomainFixture()
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let target = UUID().uuidString, operation = UUID().uuidString, message = UUID().uuidString
        let valid = Date(timeIntervalSince1970: 1_750_000_000.125)
        var request = IMV2Envelope()
        switch path {
        case "conversation", "conversation-mute":
            request.setConversationState.roomID = fixture.roomID.rawValue
            request.setConversationState.operationID = operation
        case "favorite":
            request.setMessageFavorite.roomID = fixture.roomID.rawValue
            request.setMessageFavorite.operationID = operation
            request.setMessageFavorite.messageID = message
            request.setMessageFavorite.isFavorited = true
        case "pinned":
            request.setPinnedMessage.roomID = fixture.roomID.rawValue
            request.setPinnedMessage.operationID = operation
            request.setPinnedMessage.messageID = message
            request.setPinnedMessage.isPinned = true
        case "announcement":
            request.setGroupAnnouncement.roomID = fixture.roomID.rawValue
            request.setGroupAnnouncement.operationID = operation
            request.setGroupAnnouncement.body = "updated announcement"
            request.setGroupAnnouncement.expectedRevision = 1
        case "group": request.finalizeGroupRoomCreation.operationID = operation
        case "edit":
            request.editMessage.roomID = fixture.roomID.rawValue; request.editMessage.operationID = operation
            request.editMessage.messageID = message; request.editMessage.expectedMessageRevision = 1; request.editMessage.content.text = "updated"
        case "withdraw":
            request.withdrawMessage.roomID = fixture.roomID.rawValue; request.withdrawMessage.operationID = operation
            request.withdrawMessage.messageID = message; request.withdrawMessage.expectedMessageRevision = 1
        case "reaction":
            request.changeMessageReaction.roomID = fixture.roomID.rawValue; request.changeMessageReaction.operationID = operation
            request.changeMessageReaction.messageID = message; request.changeMessageReaction.reaction = "👍"; request.changeMessageReaction.action = .add
        case "membership":
            request.changeRoomMembership.roomID = fixture.roomID.rawValue; request.changeRoomMembership.operationID = operation
            request.changeRoomMembership.targetUserID = target; request.changeRoomMembership.action = .add; request.changeRoomMembership.expectedMembershipRevision = 1
        case "redact":
            request.moderateMessage.roomID = fixture.roomID.rawValue; request.moderateMessage.operationID = operation
            request.moderateMessage.messageID = message; request.moderateMessage.reasonCode = "abuse_spam"
        case "mute", "mute-expiry":
            request.muteMember.roomID = fixture.roomID.rawValue; request.muteMember.operationID = operation
            request.muteMember.targetUserID = target; request.muteMember.reasonCode = "abuse_spam"; request.muteMember.muteUntilMs = 1_750_000_010_000
        case "remove":
            request.moderateMemberRemoval.roomID = fixture.roomID.rawValue; request.moderateMemberRemoval.operationID = operation
            request.moderateMemberRemoval.targetUserID = target; request.moderateMemberRemoval.reasonCode = "abuse_spam"
        case "relationship":
            request.changeRelationship.operationID = operation; request.changeRelationship.targetUserID = target; request.changeRelationship.action = .request
        case "block":
            request.changeUserBlock.operationID = operation; request.changeUserBlock.targetUserID = target; request.changeUserBlock.action = .block
        case "receipt":
            request.recordReadReceipt.operationID = operation; request.recordReadReceipt.roomID = fixture.roomID.rawValue; request.recordReadReceipt.readThroughRoomSequence = 3
        case "receipt-preferences": request.setReadReceiptPreferences.operationID = operation
        case "direct": request.openDirectRoom.operationID = operation; request.openDirectRoom.targetUserID = target
        case "stranger": request.setStrangerMessagePermission.operationID = operation; request.setStrangerMessagePermission.permission = .allow
        case "user-add": request.setUserAddPermission.operationID = operation; request.setUserAddPermission.permission = .allow
        case "live-set": request.setLiveActivityPreferences.operationID = operation
        case "live-get": request.getLiveActivityPreferences = .init()
        default: request.subscribePresence.roomID = fixture.roomID.rawValue
        }
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000, -Double(Int64.max) / 500] {
            let store = GatewayResponseClockStore(date: Date(timeIntervalSince1970: seconds), replay: replay,
                muteExpiryOnly: path == "mute-expiry" || path == "conversation-mute")
            let imports = V2GroupAudienceImportService(store: GatewayAudienceImportStore(),
                groupMessaging: try .init(store: store, capacityProfile: profile, roomShardID: "room-a", now: { fixture.now }),
                now: { fixture.now })
            if path == "group" {
                _ = try await imports.begin(actorUserID: fixture.userID, operationID: .init(operation), title: "clock")
                _ = try await imports.append(actorUserID: fixture.userID, operationID: .init(operation), memberUserIDs: [.init(target)])
            }
            let handler = makeGatewayDomainCommandHandler(
                sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
                membership: .init(store: store, capacityProfile: profile, now: { fixture.now }),
                withdrawal: .init(store: store, capacityProfile: profile, now: { fixture.now }),
                reaction: .init(store: store, capacityProfile: profile, now: { fixture.now }),
                edit: .init(store: store, capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { fixture.now }),
                readReceipt: .init(store: store, now: { fixture.now }), liveActivity: .init(store: store),
                directMessaging: try .init(store: store, capacityProfile: profile, roomShardID: "room-a", now: { fixture.now }),
                groupAudienceImports: imports,
                socialRelationships: .init(store: store, now: { fixture.now }),
                moderation: .init(store: store, capacityProfile: profile, now: { fixture.now }),
                conversationCapabilities: .init(store: store, now: { fixture.now }),
                groupCapabilities: .init(store: store, capacityProfile: profile, now: { fixture.now }), sync: fixture.syncService())
            let failed = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(failed.error.code == "UNAVAILABLE" && failed.error.retryable && failed.error.retryAfterSeconds == 0)
            for (recoveredDate, expectedMilliseconds) in [(valid, Int64(1_750_000_000_125)), (Date(timeIntervalSince1970: 0), 0), (Date(timeIntervalSince1970: -1.25), -1_250)] {
                await store.recover(at: recoveredDate)
                let response = try await handler.handle(envelope: request, identity: fixture.identity)
                let milliseconds: Int64
                switch path {
                case "conversation": milliseconds = response.conversationStateSet.updatedAtMs
                case "conversation-mute": milliseconds = response.conversationStateSet.muteUntilMs
                case "favorite": milliseconds = response.messageFavoriteChanged.updatedAtMs
                case "pinned": milliseconds = response.pinnedMessageChanged.updatedAtMs
                case "announcement": milliseconds = response.groupAnnouncementChanged.updatedAtMs
                case "group": milliseconds = response.groupRoomCreated.createdAtMs
                case "edit": milliseconds = response.messageEdited.serverCreatedAtMs
                case "withdraw": milliseconds = response.messageWithdrawn.serverCreatedAtMs
                case "reaction": milliseconds = response.messageReactionChanged.serverCreatedAtMs
                case "membership": milliseconds = response.membershipChanged.serverCreatedAtMs
                case "redact": milliseconds = response.messageRedacted.serverCreatedAtMs
                case "mute": milliseconds = response.memberMuted.serverCreatedAtMs
                case "mute-expiry": milliseconds = response.memberMuted.muteUntilMs
                case "remove": milliseconds = response.memberRemovedByModerator.serverCreatedAtMs
                case "relationship": milliseconds = response.relationshipChanged.updatedAtMs
                case "block": milliseconds = response.userBlockChanged.updatedAtMs
                case "receipt": milliseconds = response.readReceiptRecorded.recordedAtMs
                case "receipt-preferences": milliseconds = response.readReceiptPreferencesSet.updatedAtMs
                case "direct": milliseconds = response.directRoomOpened.createdAtMs
                case "stranger": milliseconds = response.strangerMessagePermissionSet.updatedAtMs
                case "user-add": milliseconds = response.userAddPermissionSet.updatedAtMs
                case "live-set": milliseconds = response.liveActivityPreferencesSet.updatedAtMs
                case "live-get": milliseconds = response.liveActivityPreferences.updatedAtMs
                default: milliseconds = response.presenceSubscribed.expiresAtMs
                }
                #expect(milliseconds == expectedMilliseconds)
            }
            #expect(await store.calls == 4)
        }
    }

    @Test("group revision boundaries produce correlated terminal argument errors before storage",
          arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func groupRevisionBoundary(revision: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayOwnerChangedGroupCapabilityStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()),
            groupCapabilities: .init(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile)),
            sync: fixture.syncService())
        let version = UInt8(IMV2ProtocolVersion.current)
        let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
            authenticator: GatewayResponseAuthenticator(userID: fixture.userID), capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(), now: { fixture.now })
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "local-revision-fixture"; auth.authenticate.deviceID = fixture.deviceID.rawValue
        _ = try await session.receiveBootstrap(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version))
        var expectedCalls: [String] = []
        for kind in ["announcement", "permissions", "role"] {
            var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(version)
            let operation = UUID().uuidString
            switch kind {
            case "announcement":
                request.setGroupAnnouncement.roomID = fixture.roomID.rawValue
                request.setGroupAnnouncement.operationID = operation
                request.setGroupAnnouncement.body = "Announcement"
                request.setGroupAnnouncement.expectedRevision = revision
            case "permissions":
                request.setGroupRolePermissions.roomID = fixture.roomID.rawValue
                request.setGroupRolePermissions.operationID = operation
                request.setGroupRolePermissions.role = "member"
                request.setGroupRolePermissions.expectedRevision = revision
            default:
                request.changeGroupMemberRole.roomID = fixture.roomID.rawValue
                request.changeGroupMemberRole.operationID = operation
                request.changeGroupMemberRole.userID = UserID(uuid: UUID()).rawValue
                request.changeGroupMemberRole.role = "admin"
                request.changeGroupMemberRole.expectedMembershipRevision = revision
            }
            let invalid = revision > UInt64(Int64.max) || (revision == 0 && kind != "announcement")
            // Repeating the same operation and request IDs verifies rejection
            // precedes both new/replay lookup and releases request correlation.
            for _ in 0..<2 {
                let frame = try V2ServerProtobufFrameCodec.encode(request, frameVersion: version)
                let response = try V2ServerProtobufFrameCodec.decode(await session.receiveAuthenticated(frame, handler: handler))
                #expect(response.requestID == 3 && response.protocolVersion == UInt32(version))
                #expect(response.error.code == (invalid ? "INVALID_ARGUMENT" : "UNAVAILABLE"))
                #expect(response.error.retryable == !invalid)
                if !invalid { expectedCalls.append(kind) }
                #expect(await store.calls() == expectedCalls)
            }
        }
        #expect(await session.authenticatedIdentity() != nil)
        await session.close()
    }

    @Test("invalid unsubscribe room IDs return argument errors without closing or removing subscriptions",
          arguments: ["group", "presence", "typing"])
    func unsubscribeRoomValidation(kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let registry = V2DeviceConnectionRegistry(), connectionID = UUID()
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()), sync: fixture.syncService())
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: GatewayResponseAuthenticator(userID: fixture.userID),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: handler, connectionID: connectionID, registry: registry)
        func exchange(_ request: IMV2Envelope, version: UInt8) async throws -> IMV2Envelope {
            let frame = try V2ServerProtobufFrameCodec.encode(request, frameVersion: version)
            let responses = try await stream.receive(V2FrameCodec.encode(frame, limits: limits))
            #expect(responses.count == 1)
            return try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(#require(responses.first), limits: limits))
        }
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await exchange(hello, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "local-fixture"; auth.authenticate.deviceID = fixture.deviceID.rawValue
        _ = try await exchange(auth, version: version)
        let delivered = Mutex<[Data]>([])
        await stream.setOutboundWriter { data in delivered.withLock { $0.append(data) } }
        let room = fixture.roomID, subject = UserID(uuid: UUID())
        switch kind {
        case "group": await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: room)
        case "presence": await registry.subscribePresence(stream, connectionID: connectionID, roomID: room, targetUserID: subject)
        default: await registry.subscribeTyping(stream, connectionID: connectionID, roomID: room)
        }
        func publish() async {
            let expiry = fixture.now.addingTimeInterval(6)
            switch kind {
            case "group": await registry.notifyForegroundGroupAvailable(roomID: room, highWatermark: 9)
            case "presence": await registry.receivePresence(targetUserID: subject, isOnline: true, expiresAt: expiry)
            default: await registry.receiveTyping(.init(roomID: room, userID: subject, isTyping: true, expiresAt: expiry))
            }
        }
        func request(roomID: String) -> IMV2Envelope {
            var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(version)
            switch kind {
            case "group": request.groupEventUnsubscribe.roomID = roomID
            case "presence": request.unsubscribePresence.roomID = roomID
            default: request.unsubscribeTyping.roomID = roomID
            }
            return request
        }
        var expectedNotifications = 0
        for invalidRoom in ["", " ", "room/invalid", String(repeating: "a", count: 129)] {
            let rejected = try await exchange(request(roomID: invalidRoom), version: version)
            #expect(rejected.requestID == 3)
            #expect(rejected.error.code == "INVALID_ARGUMENT" && !rejected.error.retryable)
            #expect(await stream.isAuthenticated())
            await publish()
            expectedNotifications += 1
            #expect(delivered.withLock { $0.count } == expectedNotifications)
        }
        // Reusing the completed request ID also verifies the in-flight slot
        // was released after each argument error. Repeated cleanup is harmless.
        for _ in 0..<2 {
            let accepted = try await exchange(request(roomID: room.rawValue), version: version)
            guard case .acknowledged? = accepted.body else {
                Issue.record("Expected successful unsubscribe acknowledgement")
                return
            }
            await publish()
            #expect(delivered.withLock { $0.count } == expectedNotifications)
        }
        #expect(await stream.isAuthenticated())
        try await stream.finish()
    }

    @Test("UUIDv7 clock failures return retryable Gateway responses before message writes")
    func sendIdentifierClockFailureIsRetryable() async throws {
        let fixture = try GatewayDomainFixture()
        let clock = Mutex(fixture.now)
        let accepted = V2AcceptedMessage(messageID: .init(uuid: UUID()), roomID: fixture.roomID, roomSequence: 9,
            senderUserID: fixture.userID, clientMessageID: fixture.clientMessageID,
            text: "hello", mediaPresentations: [],
            sourceEventID: .init(uuid: UUID()), acceptedMembershipRevision: 3,
            directRecipientUserID: .init(uuid: UUID()), createdAt: fixture.now)
        let store = GatewayTimestampSequenceStore(outcomes: [.accepted(accepted)])
        let hints = GatewayForegroundHintRecorder()
        let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 16), now: { clock.withLock { $0 } })
        let handler = makeGatewayDomainCommandHandler(sendMessage: service, foregroundGroupEventHints: hints, sync: fixture.syncService())
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        let invalidSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, -1, 1e14, -1e14, -1e12, 281_474_976_710.656, 946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 10]
        for seconds in invalidSeconds {
            clock.withLock { $0 = Date(timeIntervalSince1970: seconds) }
            let rejected = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(rejected.error.code == "UNAVAILABLE")
            #expect(rejected.error.retryable)
            #expect(await store.outcomes.count == 1)
            #expect(hints.values().isEmpty)
        }
        clock.withLock { $0 = fixture.now }
        let recovered = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(recovered.messageAccepted.messageID == accepted.messageID.rawValue)
        #expect(recovered.messageAccepted.serverCreatedAtMs == 1_750_000_000_000)
        #expect(await store.outcomes.isEmpty)
    }

    @Test("Group intent persistence failures return a retryable Gateway response")
    func groupIntentClockFailureIsRetryable() async throws {
        let fixture = try GatewayDomainFixture()
        let imports = V2GroupAudienceImportService(store: GatewayAudienceImportStore(),
            groupMessaging: try .init(store: GatewayGroupIntentClockFailure(),
                capacityProfile: .init(id: "standard", limits: fixture.profile),
                roomShardID: "rooms-primary", now: { fixture.now }), now: { fixture.now })
        let operation = GroupRoomOperationID(uuid: UUID())
        _ = try await imports.begin(actorUserID: fixture.userID, operationID: operation, title: "clock")
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()),
            groupAudienceImports: imports, sync: fixture.syncService())
        var request = IMV2Envelope()
        request.finalizeGroupRoomCreation.operationID = operation.rawValue
        for _ in 0..<2 {
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        }
    }

    @Test("Personal timestamp validation distinguishes unsupported input from an unavailable server clock",
          arguments: [V2ConversationCapabilitiesStoreError.invalidTimestamp, .corruptPersistenceState])
    func personalTimestampErrorMapping(error: V2ConversationCapabilitiesStoreError) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()),
            conversationCapabilities: .init(store: GatewayPersonalTimestampFailure(error: error)), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.setConversationState.roomID = fixture.roomID.rawValue
        request.setConversationState.operationID = UUID().uuidString
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == (error == .invalidTimestamp ? "INVALID_ARGUMENT" : "UNAVAILABLE"))
        #expect(response.error.retryable == (error == .corruptPersistenceState))
    }

    @Test("Both draft responses reject counts outside the unsigned wire range",
          arguments: [-1, 0, 7, Int(UInt32.max), Int(UInt32.max) + 1, Int.max])
    func draftCountBoundary(count: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let imports = V2GroupAudienceImportService(store: GatewayAudienceImportStore(returnedMemberCount: count),
            groupMessaging: try .init(store: GatewayGroupStore(), capacityProfile: .init(id: "standard", limits: fixture.profile),
                                     roomShardID: "rooms-primary", now: { fixture.now }), now: { fixture.now })
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()),
            groupAudienceImports: imports, sync: fixture.syncService())
        let operation = UUID().uuidString
        var begin = IMV2Envelope()
        begin.beginGroupRoomCreation.operationID = operation
        begin.beginGroupRoomCreation.title = "boundary"
        var append = IMV2Envelope()
        append.appendGroupRoomCreationMembers.operationID = operation
        append.appendGroupRoomCreationMembers.memberUserIds = [UUID().uuidString]
        let prepared = try await handler.handle(envelope: begin, identity: fixture.identity)
        let appended = try await handler.handle(envelope: append, identity: fixture.identity)
        if let expected = UInt32(exactly: count) {
            #expect(prepared.groupRoomCreationPrepared.stagedMemberCount == expected)
            #expect(appended.groupRoomCreationMembersAppended.stagedMemberCount == expected)
            #expect(prepared.error.code.isEmpty && appended.error.code.isEmpty)
        } else {
            #expect(prepared.error.code == "UNAVAILABLE" && prepared.error.retryable)
            #expect(appended.error.code == "UNAVAILABLE" && appended.error.retryable)
        }
    }

    @Test("Created and replayed group results check member counts before wire conversion",
          arguments: [false, true], [Int.min, -1, 0, 1, 2, Int(UInt32.max), Int(UInt32.max) + 1, Int.max])
    func createdGroupCountBoundary(replay: Bool, count: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let audience = GatewayAudienceImportStore()
        let imports = V2GroupAudienceImportService(store: audience,
            groupMessaging: try .init(store: GatewayGroupStore(returnedMemberCount: count, replay: replay),
                capacityProfile: .init(id: "standard", limits: fixture.profile), roomShardID: "rooms-primary", now: { fixture.now }),
            now: { fixture.now })
        let operation = GroupRoomOperationID(uuid: UUID())
        _ = try await imports.begin(actorUserID: fixture.userID, operationID: operation, title: "boundary")
        _ = try await imports.append(actorUserID: fixture.userID, operationID: operation, memberUserIDs: [.init(uuid: UUID())])
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()),
            groupAudienceImports: imports, sync: fixture.syncService())
        var request = IMV2Envelope()
        request.finalizeGroupRoomCreation.operationID = operation.rawValue
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        if count >= 2, let expected = UInt32(exactly: count) {
            #expect(response.groupRoomCreated.memberCount == expected)
            #expect(response.error.code.isEmpty)
        } else {
            #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        }
    }

    @Test("Gateway rate-limit responses reject invalid intervals without truncation",
          arguments: [-1, 0, 7, Int(UInt32.max), Int(UInt32.max) + 1, Int.max])
    func retryIntervalBoundary(seconds: Int) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: seconds))),
            sync: fixture.syncService())
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        if let expected = UInt32(exactly: seconds) {
            #expect(response.error.code == "RATE_LIMITED")
            #expect(response.error.retryAfterSeconds == expected)
        } else {
            #expect(response.error.code == "UNAVAILABLE")
            #expect(response.error.retryAfterSeconds == 0)
        }
        #expect(response.error.retryable)
    }

    @Test("A broken telemetry clock does not turn a successful replay into a failure",
          arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func telemetryClockBoundary(seconds: Double) async throws {
        let fixture = try GatewayDomainFixture()
        let metricInstant = ContinuousClock.now
        let message = V2AcceptedMessage(messageID: .init(uuid: UUID()), roomID: fixture.roomID,
            roomSequence: 9, senderUserID: fixture.userID, clientMessageID: fixture.clientMessageID,
            text: "hello", mediaPresentations: [], createdAt: fixture.now)
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .idempotent(message.receipt))),
            sync: fixture.syncService(), telemetry: telemetry, now: { Date(timeIntervalSince1970: seconds) },
            monotonicNow: { metricInstant })
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.messageAccepted.messageID == message.messageID.rawValue)
        guard case .gatewayCommand(_, .sendMessage, .accepted, nil, 0) = await telemetry.events().first else {
            Issue.record("Expected a successful replay metric with zero elapsed monotonic time")
            return
        }
    }

    @Test("Invalid committed and replay timestamps return unavailable and allow a valid retry",
          arguments: [false, true], [Double.nan, .infinity, -.infinity, Double(Int64.max) / 1_000, -.greatestFiniteMagnitude])
    func responseTimestampBoundary(replay: Bool, seconds: Double) async throws {
        let fixture = try GatewayDomainFixture()
        func message(at date: Date) -> V2AcceptedMessage {
            .init(messageID: .init(uuid: UUID()), roomID: fixture.roomID, roomSequence: 9,
                  senderUserID: fixture.userID, clientMessageID: fixture.clientMessageID,
                  text: "hello", mediaPresentations: [],
                  sourceEventID: .init(uuid: UUID()), acceptedMembershipRevision: 3,
                  directRecipientUserID: .init(uuid: UUID()), createdAt: date)
        }
        let invalid = message(at: Date(timeIntervalSince1970: seconds))
        let valid = message(at: Date(timeIntervalSince1970: 1_750_000_000.125))
        let store = GatewayTimestampSequenceStore(outcomes: [
            replay ? .idempotent(invalid.receipt) : .accepted(invalid), .idempotent(valid.receipt)
        ])
        let hints = GatewayForegroundHintRecorder()
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: store),
            foregroundGroupEventHints: hints, sync: fixture.syncService())
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        let rejected = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(rejected.error.code == "UNAVAILABLE" && rejected.error.retryable)
        #expect(hints.values().isEmpty)
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.messageAccepted.serverCreatedAtMs == 1_750_000_000_125)
        #expect(response.messageAccepted.messageID == valid.messageID.rawValue)
    }

    @Test("send owner changes map to retryable unavailable")
    func sendOwnerChangeIsRetryable() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: GatewayOwnerChangedSendStore()), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content.text = "hello"
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
    }

    @Test("database admission rejects overload with a stable retryable protocol error")
    func databaseAdmissionReturnsServerBusy() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(
                seed: [(fixture.roomState, fixture.shardState)],
                authorizedActors: [fixture.userID]
            )),
            sync: fixture.syncService(),
            telemetry: telemetry,
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "SERVER_BUSY")
        #expect(response.error.retryable)
        var baseline = IMV2Envelope(); baseline.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue
        #expect(try await handler.handle(envelope: baseline, identity: fixture.identity).error.code == "SERVER_BUSY")
        var latest = IMV2Envelope(); latest.roomLatestVisibleBatch.roomIds = [fixture.roomID.rawValue]
        let latestBusy = try await handler.handle(envelope: latest, identity: fixture.identity)
        #expect(latestBusy.error.code == "SERVER_BUSY" && latestBusy.error.retryable)
        guard case .gatewayCommand(_, .sendMessage, .rejected, .serverBusy, _) =
            await telemetry.events().first
        else {
            Issue.record("expected a privacy-safe server-busy metric")
            await admission.release(.foregroundWrite)
            await admission.release(.interactiveRead)
            return
        }
        await admission.release(.foregroundWrite)
        await admission.release(.interactiveRead)
    }

    @Test("a batch-owned send skips per-request gateway admission and maps overload to server busy")
    func batchOwnedSendUsesItsOwnDatabaseAdmissionBoundary() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 2,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        // One of two write permits is occupied. A correct handler leaves the
        // remaining permit for the batcher; a handler that admits once here
        // and once in the batcher would return SERVER_BUSY instead.
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        let store = GatewayAtomicBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(1)),
            databaseWorkAdmission: admission
        )
        let sendMessage = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 16),
            batcher: batcher,
            now: { fixture.now }
        )
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: sendMessage,
            sync: fixture.syncService(),
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "RATE_LIMITED")
        #expect(response.error.retryable)
        let snapshot = await admission.snapshot()
        #expect(snapshot.foregroundWrite.admittedRequests == 2)
        #expect(snapshot.foregroundWrite.inFlight == 1)
        await admission.release(.foregroundWrite)
    }

    @Test("room-log pulls use the interactive-read reservation instead of send capacity")
    func groupEventPullUsesInteractiveReadAdmission() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let queuedRead = Task { await admission.acquire(.interactiveRead) }
        while await admission.snapshot().interactiveReadQueued == 0 {
            await Task.yield()
        }
        let telemetry = V2InMemoryTelemetrySink()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(
                seed: [(fixture.roomState, fixture.shardState)],
                authorizedActors: [fixture.userID]
            )),
            sync: fixture.syncService(),
            telemetry: telemetry,
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = fixture.roomID.rawValue
        request.groupEventPull.pageSize = 100

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "SERVER_BUSY")
        guard case .gatewayCommand(_, .groupEventPull, .rejected, .serverBusy, _) =
            await telemetry.events().first
        else {
            Issue.record("expected room-log pull telemetry instead of unsupported")
            await admission.release(.interactiveRead)
            _ = await queuedRead.value
            await admission.release(.interactiveRead)
            await admission.release(.foregroundWrite)
            return
        }
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.queueFullRejections == 1)
        #expect(snapshot.foregroundWrite.rejectedRequests == 0)
        await admission.release(.interactiveRead)
        #expect(await queuedRead.value == .admitted)
        await admission.release(.interactiveRead)
        await admission.release(.foregroundWrite)
    }

    @Test("cancelling admission wait propagates cancellation instead of server busy")
    func databaseAdmissionCancellationPropagates() async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .seconds(1)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(
                seed: [(fixture.roomState, fixture.shardState)],
                authorizedActors: [fixture.userID]
            )),
            sync: fixture.syncService(),
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let waiting = Task {
            try await handler.handle(envelope: request, identity: fixture.identity)
        }
        while await admission.snapshot().foregroundWriteQueued == 0 {
            await Task.yield()
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(await admission.snapshot().foregroundWrite.cancelledRequests == 1)
        await admission.release(.foregroundWrite)
        await admission.release(.interactiveRead)
    }

    @Test("process-local unsubscribe remains available during database overload", arguments: ["group", "presence", "typing"])
    func databaseAdmissionBypassesUnsubscribe(kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .milliseconds(5)
        ))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(
                seed: [(fixture.roomState, fixture.shardState)],
                authorizedActors: [fixture.userID]
            )),
            sync: fixture.syncService(),
            databaseWorkAdmission: admission
        )
        var request = IMV2Envelope()
        switch kind {
        case "group": request.groupEventUnsubscribe.roomID = fixture.roomID.rawValue
        case "presence": request.unsubscribePresence.roomID = fixture.roomID.rawValue
        default: request.unsubscribeTyping.roomID = fixture.roomID.rawValue
        }

        let response = try await handler.handle(
            envelope: request,
            identity: fixture.identity
        )
        guard case .some(.acknowledged) = response.body else {
            Issue.record("expected process-local unsubscribe success")
            await admission.release(.foregroundWrite)
            return
        }
        #expect(await admission.snapshot().foregroundWriteQueued == 0)
        await admission.release(.foregroundWrite)
    }

    @Test("a database pool timeout returns unavailable without escaping the command boundary")
    func databasePoolTimeoutKeepsCommandBoundaryAlive() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayPoolTimeoutMessageStore()),
            sync: fixture.syncService()
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.error.code == "UNAVAILABLE")
        #expect(response.error.retryable)
    }

    @Test("a room capacity profile mismatch is retryable and does not escape the command boundary")
    func capacityProfileMismatchKeepsCommandBoundaryAlive() async throws {
        let fixture = try GatewayDomainFixture()
        let telemetry = V2InMemoryTelemetrySink()
        let store = InMemoryV2RoomWriteStore(
            seed: [(fixture.roomState, fixture.shardState)],
            authorizedActors: [fixture.userID],
            capacityProfileID: "legacy"
        )
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: store),
            sync: fixture.syncService(),
            telemetry: telemetry
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "hello"

        let first = try await handler.handle(envelope: request, identity: fixture.identity)
        request.sendMessage.clientMessageID = UUID().uuidString
        let second = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(first.error.code == "UNAVAILABLE")
        #expect(first.error.retryable)
        #expect(second.error.code == "UNAVAILABLE")
        let events = await telemetry.events()
        #expect(events.count == 2)
        for event in events {
            guard case .gatewayCommand(_, .sendMessage, .rejected, .unavailable, _) = event else {
                Issue.record("expected a bounded unavailable rejection")
                return
            }
        }
    }

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
        let metricInstant = ContinuousClock.now
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: store),
            sync: fixture.syncService(),
            telemetry: telemetry,
            now: { fixture.now }, monotonicNow: { metricInstant }
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
        #expect(!attachmentResponse.messageAccepted.messageID.isEmpty)
        #expect(attachmentResponse.messageAccepted.roomSequence > 0)
        let state = try #require(await store.state(for: fixture.roomID))
        let accepted = try #require(state.0.acceptedCommands.values.first)
        #expect(accepted.acceptedMessage.senderUserID == fixture.identity.userID)

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
            groupCapacityClass: .standard,
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
        #expect(hints.values() == [.init(roomID: fixture.roomID, highWatermark: 9)])
    }

    @Test("an accepted direct room-log message emits only a best-effort foreground watermark hint")
    func acceptedDirectRoomLogMessagePublishesForegroundHint() async throws {
        let fixture = try GatewayDomainFixture()
        let accepted = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000041"),
            roomID: fixture.roomID,
            roomSequence: 10,
            senderUserID: fixture.userID,
            clientMessageID: fixture.clientMessageID,
            text: "private-log",
            mediaPresentations: [],

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
        request.sendMessage.content.text = "private-log"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.messageAccepted.roomSequence == 10)
        #expect(hints.values() == [.init(roomID: fixture.roomID, highWatermark: 10)])
    }

    @Test("an accepted direct event excludes only the originating connection")
    func acceptedDirectEventCarriesOriginExclusion() async throws {
        let fixture = try GatewayDomainFixture()
        let recipientID = try UserID("00000000-0000-0000-0000-000000000042")
        let accepted = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000043"),
            roomID: fixture.roomID,
            roomSequence: 11,
            senderUserID: fixture.userID,
            clientMessageID: fixture.clientMessageID,
            text: "private-live",
            mediaPresentations: [],

            sourceEventID: try .init("00000000-0000-0000-0000-000000000044"),
            acceptedMembershipRevision: 3,
            directRecipientUserID: recipientID,
            createdAt: fixture.now
        )
        let hints = GatewayForegroundHintRecorder()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(
                store: GatewayAcceptedMessageStore(outcome: .accepted(accepted))
            ),
            foregroundGroupEventHints: hints,
            sync: fixture.syncService()
        )
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = "private-live"
        let connectionID = UUID()

        let response = try await handler.handle(
            envelope: request,
            identity: fixture.identity,
            originatingConnectionID: connectionID
        )

        #expect(response.messageAccepted.roomSequence == 11)
        #expect(hints.values() == [.init(roomID: fixture.roomID, highWatermark: 11)])
        #expect(hints.directExclusions() == [connectionID])
    }

    @Test("an accepted plain Hybrid group handler emits a fenced live event")
    func acceptedHybridGroupHandlerEmitsFencedLiveEvent() async throws {
        let fixture = try GatewayDomainFixture()
        let accepted = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000053"),
            roomID: fixture.roomID,
            roomSequence: 12,
            senderUserID: fixture.userID,
            clientMessageID: fixture.clientMessageID,
            text: "group-live",
            mediaPresentations: [],
            groupCapacityClass: .large,

            sourceEventID: try .init("00000000-0000-0000-0000-000000000054"),
            acceptedMembershipRevision: 7,
            createdAt: fixture.now
        )
        let hints = GatewayForegroundHintRecorder()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(
                store: GatewayAcceptedMessageStore(outcome: .accepted(accepted))
            ),
            foregroundGroupEventHints: hints,
            sync: fixture.syncService()
        )
        var request = IMV2Envelope(); request.sendMessage = .init()
        request.sendMessage.roomID = fixture.roomID.rawValue
        request.sendMessage.clientMessageID = fixture.clientMessageID.rawValue
        request.sendMessage.content = .init(); request.sendMessage.content.text = "group-live"

        let response = try await handler.handle(envelope: request, identity: fixture.identity)

        #expect(response.messageAccepted.roomSequence == 12)
        #expect(hints.groupMembershipRevisions() == [7])
        #expect(hints.values() == [.init(roomID: fixture.roomID, highWatermark: 12)])
    }

    @Test("snapshot rebuild reaches the sync store with the authenticated device")
    func forwardsSnapshotRebuild() async throws {
        let fixture = try GatewayDomainFixture()
        let received = Mutex<(UserID, DeviceID, Bool)?>(nil)
        let store = GatewayRejectingSyncStore(onPull: { userID, deviceID, requireSnapshot in
            received.withLock { $0 = (userID, deviceID, requireSnapshot) }
        })
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(
                seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID]
            )),
            sync: .init(store: store)
        )
        var pull = IMV2Envelope()
        pull.syncPull.requireSnapshot = true
        let response = try await handler.handle(envelope: pull, identity: fixture.identity)
        #expect(response.error.code == "SYNC_TOKEN_INVALID")
        let request = try #require(received.withLock { $0 })
        #expect(request.0 == fixture.userID)
        #expect(request.1 == fixture.deviceID)
        #expect(request.2)
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

    @Test("Sync generations and sequences reject unsupported integers before storage and preserve valid boundaries",
          arguments: ["ack-generation", "ack-sequence", "manifest", "page", "snapshot-generation", "snapshot-sequence"])
    func syncRequestIntegerBoundaries(path: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewaySyncBoundaryStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            sync: .init(store: store, now: { fixture.now }))
        let sequencePath = path.hasSuffix("sequence")
        func request(_ value: UInt64) -> IMV2Envelope {
            let generation: UInt64 = sequencePath ? 1 : value
            let sequence: UInt64 = sequencePath ? value : 0
            var result = IMV2Envelope()
            switch path {
            case "ack-generation", "ack-sequence":
                result.syncAck.generation = generation
                result.syncAck.highestContiguousSequence = sequence
                result.syncAck.syncReceipt = "boundary-receipt"
            case "manifest":
                result.syncSnapshot.generation = generation
                result.syncSnapshot.snapshotID = store.snapshotID.rawValue
            case "page":
                result.snapshotPagePull.generation = generation
                result.snapshotPagePull.snapshotID = store.snapshotID.rawValue
                result.snapshotPagePull.rootDigest = "boundary-root"
            default:
                result.snapshotAck.generation = generation
                result.snapshotAck.baseUserSyncSequence = sequence
                result.snapshotAck.snapshotID = store.snapshotID.rawValue
                result.snapshotAck.snapshotReceipt = "boundary-receipt"
            }
            return result
        }
        let invalid: [UInt64] = (sequencePath ? [] : [0]) + [UInt64(Int64.max) + 1, UInt64.max]
        let valid: [UInt64] = (sequencePath ? [0] : []) + [1, UInt64(Int64.max)]
        var expectedCalls = 0
        for value in valid {
            // Repeat invalid inputs before each valid boundary to cover the
            // same service instance both before and after successful calls.
            for bad in invalid {
                let response = try await handler.handle(envelope: request(bad), identity: fixture.identity)
                #expect(response.error.code == "INVALID_ARGUMENT" && !response.error.retryable)
                #expect(await store.calls == expectedCalls)
            }
            let response = try await handler.handle(envelope: request(value), identity: fixture.identity)
            #expect(response.error.code.isEmpty)
            expectedCalls += 1
            #expect(await store.calls == expectedCalls)
            #expect(await store.lastGeneration == (sequencePath ? 1 : value))
            if sequencePath { #expect(await store.lastSequence == value) }
        }
    }

    @Test("Sync response failures use stable protocol errors and recover after storage becomes available",
          arguments: [V2SyncStoreError.syncLogSequenceGap, .snapshotCheckpointUnavailable, .syncRecordTooLarge])
    func syncResponseFailureRecovery(error: V2SyncStoreError) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayRecoveringSyncStore(failure: error)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: GatewayAcceptedMessageStore(outcome: .rateLimited(retryAfterSeconds: 1))),
            sync: .init(store: store, now: { fixture.now }))
        var request = IMV2Envelope()
        request.syncPull.maxRecords = 10
        request.syncPull.requireSnapshot = error == .snapshotCheckpointUnavailable
        for _ in 0..<2 {
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == (error == .syncRecordTooLarge ? "SYNC_RECORD_TOO_LARGE" : "UNAVAILABLE"))
            #expect(response.error.retryable == (error != .syncRecordTooLarge))
            #expect(response.error.retryAfterSeconds == 0)
            #expect(response.body == .error(response.error))
        }
        await store.recover()
        let recovered = try await handler.handle(envelope: request, identity: fixture.identity)
        if request.syncPull.requireSnapshot {
            #expect(recovered.error.code == "RESET_PREPARING" && recovered.error.retryable)
            #expect(recovered.error.retryAfterSeconds == 1)
        } else {
            #expect(recovered.body == .syncBatch(recovered.syncBatch) && recovered.error.code.isEmpty)
            #expect(recovered.syncBatch.generation == 1 && recovered.syncBatch.records.isEmpty)
            #expect(recovered.syncBatch.nextSyncToken == "recovered-token")
            #expect(recovered.syncBatch.syncReceipt == "recovered-receipt" && !recovered.syncBatch.hasMore_p)
        }
        #expect(await store.calls == 3)
    }

    @Test("durable forward pending is retryable and never a terminal pair response", arguments: [false, true])
    func forwardPending(paused: Bool) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            forwardMessages: GatewayPendingForward(paused: paused), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.forwardMessages.operationID = UUID().uuidString
        request.forwardMessages.targetRoomIds = [fixture.roomID.rawValue]
        var source = IMV2ForwardMessageReference()
        source.messageID = UUID().uuidString; source.roomID = fixture.roomID.rawValue; source.revision = 1
        request.forwardMessages.sources = [source]
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == (paused ? "FORWARD_PAUSED" : "FORWARD_PENDING"))
        #expect(response.error.retryable)
        #expect(response.messagesForwarded.results.isEmpty)
    }

    @Test("forward response rejects unpersistable success sequences and preserves failed pairs", arguments: [false, true], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func forwardResponseSequenceBounds(failed: Bool, sequence: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            forwardMessages: GatewayForwardSequence(sequence: sequence, failed: failed), sync: fixture.syncService())
        var request = IMV2Envelope()
        request.forwardMessages.operationID = UUID().uuidString
        request.forwardMessages.targetRoomIds = [fixture.roomID.rawValue]
        var source = IMV2ForwardMessageReference()
        source.messageID = UUID().uuidString; source.roomID = fixture.roomID.rawValue; source.revision = 1
        request.forwardMessages.sources = [source]
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        if !failed && (sequence == 0 || sequence > UInt64(Int64.max)) {
            #expect(response.error.code == "UNAVAILABLE")
            #expect(response.error.retryable)
            #expect(response.messagesForwarded.results.isEmpty)
        } else {
            let value = try #require(response.messagesForwarded.results.first)
            #expect(value.roomSequence == (failed ? 0 : sequence))
            #expect(value.errorCode == (failed ? "FORBIDDEN" : ""))
        }
    }

    @Test("forward requires bounded source room and selected revision before calling its handler")
    func malformedForwardSource() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            sync: fixture.syncService()
        )
        for scenario in 0..<6 {
            var request = IMV2Envelope()
            request.forwardMessages.operationID = UUID().uuidString + (scenario == 5 ? "-f0" : "")
            request.forwardMessages.targetRoomIds = [fixture.roomID.rawValue]
            var source = IMV2ForwardMessageReference()
            source.messageID = UUID().uuidString
            source.roomID = scenario == 1 ? "" : fixture.roomID.rawValue
            source.revision = scenario == 2 ? 0 : (scenario == 3 ? UInt64.max : 1)
            request.forwardMessages.sources = scenario == 0 ? [] : (scenario == 4 ? [source, source] : [source])
            let response = try await handler.handle(envelope: request, identity: fixture.identity)
            #expect(response.error.code == "INVALID_ARGUMENT")
            #expect(!response.error.retryable)
        }
    }

    @Test("overflowing revision commands return INVALID_ARGUMENT without reaching storage", arguments: [UInt64(Int64.max) + 1, UInt64.max])
    func overflowingRevisionsAreProtocolErrors(_ revision: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayRevisionBoundaryStore()
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membership: .init(store: store, capacityProfile: profile),
            withdrawal: .init(store: store, capacityProfile: profile),
            edit: .init(store: store, capacityProfile: profile, maximumTextUTF8Bytes: 64),
            sync: fixture.syncService()
        )
        let operation = "00000000-0000-0000-0000-000000000016"
        let target = "00000000-0000-0000-0000-000000000017"
        var membership = IMV2Envelope()
        membership.changeRoomMembership.roomID = fixture.roomID.rawValue
        membership.changeRoomMembership.operationID = operation
        membership.changeRoomMembership.targetUserID = target
        membership.changeRoomMembership.action = .add
        membership.changeRoomMembership.expectedMembershipRevision = revision
        var edit = IMV2Envelope()
        edit.editMessage.roomID = fixture.roomID.rawValue
        edit.editMessage.operationID = operation
        edit.editMessage.messageID = target
        edit.editMessage.expectedMessageRevision = revision
        edit.editMessage.content.text = "replacement"
        var withdrawal = IMV2Envelope()
        withdrawal.withdrawMessage.roomID = fixture.roomID.rawValue
        withdrawal.withdrawMessage.operationID = operation
        withdrawal.withdrawMessage.messageID = target
        withdrawal.withdrawMessage.expectedMessageRevision = revision
        // Repeat the same operation IDs: invalid input is rejected before
        // either a new-operation or durable replay lookup can run.
        for envelope in [membership, edit, withdrawal, membership, edit, withdrawal] {
            let response = try await handler.handle(envelope: envelope, identity: fixture.identity)
            #expect(response.error.code == "INVALID_ARGUMENT")
            #expect(!response.error.retryable)
        }
        #expect(await store.calls() == 0)
    }

    @Test("conflict responses preserve bounded revisions and reject storage overflow", arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func conflictResponseRevisionBounds(_ revision: UInt64) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayRevisionBoundaryStore(conflictRevision: revision)
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membership: .init(store: store, capacityProfile: profile),
            withdrawal: .init(store: store, capacityProfile: profile),
            edit: .init(store: store, capacityProfile: profile, maximumTextUTF8Bytes: 64),
            sync: fixture.syncService()
        )
        let operation = "00000000-0000-0000-0000-000000000016"
        let target = "00000000-0000-0000-0000-000000000017"
        var membership = IMV2Envelope()
        membership.changeRoomMembership.roomID = fixture.roomID.rawValue
        membership.changeRoomMembership.operationID = operation
        membership.changeRoomMembership.targetUserID = target
        membership.changeRoomMembership.action = .add
        membership.changeRoomMembership.expectedMembershipRevision = 1
        var edit = IMV2Envelope()
        edit.editMessage.roomID = fixture.roomID.rawValue
        edit.editMessage.operationID = operation
        edit.editMessage.messageID = target
        edit.editMessage.expectedMessageRevision = 1
        edit.editMessage.content.text = "replacement"
        var withdrawal = IMV2Envelope()
        withdrawal.withdrawMessage.roomID = fixture.roomID.rawValue
        withdrawal.withdrawMessage.operationID = operation
        withdrawal.withdrawMessage.messageID = target
        withdrawal.withdrawMessage.expectedMessageRevision = 1
        for envelope in [membership, edit, withdrawal] {
            let response = try await handler.handle(envelope: envelope, identity: fixture.identity)
            #expect(response.error.code == (revision > UInt64(Int64.max) ? "UNAVAILABLE" : "REVISION_CONFLICT"))
            #expect(response.error.retryable == (revision > UInt64(Int64.max)))
            #expect(response.error.currentRevision == (revision > UInt64(Int64.max) ? 0 : revision))
        }
        #expect(await store.calls() == 3)
    }

    @Test("message mutation owner changes return retryable unavailability", arguments: ["edit", "withdraw", "reaction"])
    func messageMutationOwnerChangeIsRetryable(_ kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayOwnerChangedMutationStore()
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            withdrawal: .init(store: store, capacityProfile: profile),
            reaction: .init(store: store, capacityProfile: profile),
            edit: .init(store: store, capacityProfile: profile, maximumTextUTF8Bytes: 64),
            sync: fixture.syncService()
        )
        let operation = "00000000-0000-0000-0000-000000000016"
        let message = "00000000-0000-0000-0000-000000000017"
        var request = IMV2Envelope()
        switch kind {
        case "edit":
            request.editMessage.roomID = fixture.roomID.rawValue
            request.editMessage.operationID = operation
            request.editMessage.messageID = message
            request.editMessage.expectedMessageRevision = 1
            request.editMessage.content.text = "replacement"
        case "withdraw":
            request.withdrawMessage.roomID = fixture.roomID.rawValue
            request.withdrawMessage.operationID = operation
            request.withdrawMessage.messageID = message
            request.withdrawMessage.expectedMessageRevision = 1
        default:
            request.changeMessageReaction.roomID = fixture.roomID.rawValue
            request.changeMessageReaction.operationID = operation
            request.changeMessageReaction.messageID = message
            request.changeMessageReaction.reaction = "👍"
            request.changeMessageReaction.action = .add
        }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        #expect(await store.calls() == [kind])
    }

    @Test("group capability owner changes return retryable unavailability", arguments: ["pin", "announcement", "permissions", "role"])
    func groupCapabilityOwnerChangeIsRetryable(_ kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayOwnerChangedGroupCapabilityStore()
        let profile = try V2CapacityProfile(id: "standard", limits: fixture.profile)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupCapabilities: .init(store: store, capacityProfile: profile),
            sync: fixture.syncService()
        )
        let operation = "00000000-0000-0000-0000-000000000016"
        let target = "00000000-0000-0000-0000-000000000017"
        var request = IMV2Envelope()
        switch kind {
        case "pin":
            request.setPinnedMessage.roomID = fixture.roomID.rawValue
            request.setPinnedMessage.operationID = operation
            request.setPinnedMessage.messageID = target
            request.setPinnedMessage.isPinned = true
        case "announcement":
            request.setGroupAnnouncement.roomID = fixture.roomID.rawValue
            request.setGroupAnnouncement.operationID = operation
            request.setGroupAnnouncement.body = "announcement"
            request.setGroupAnnouncement.expectedRevision = 0
        case "permissions":
            request.setGroupRolePermissions.roomID = fixture.roomID.rawValue
            request.setGroupRolePermissions.operationID = operation
            request.setGroupRolePermissions.role = "member"
            request.setGroupRolePermissions.expectedRevision = 1
        default:
            request.changeGroupMemberRole.roomID = fixture.roomID.rawValue
            request.changeGroupMemberRole.operationID = operation
            request.changeGroupMemberRole.userID = target
            request.changeGroupMemberRole.role = "admin"
            request.changeGroupMemberRole.expectedMembershipRevision = 1
        }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        #expect(await store.calls() == [kind])
    }

    @Test("membership owner change returns retryable unavailability")
    func membershipOwnerChangeIsRetryable() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membership: .init(store: GatewayMembershipStore(failure: .ownerChanged), capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
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
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
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

    @Test("room-log pulls trim a valid page to the exact gateway payload budget")
    func groupEventPullRespectsGatewayPayloadBudget() async throws {
        let fixture = try GatewayDomainFixture()
        let roomID = fixture.roomID
        let entries = try (1...8).map { sequence in
            try V2GroupEventLogEntry(
                sourceEventID: try .init(String(format: "00000000-0000-0000-0000-%012d", sequence)),
                roomSequence: UInt64(sequence),
                projectionKind: "message.accepted",
                payload: Data(repeating: 0x78, count: 700)
            )
        }
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupEventLog: .init(store: GatewaySizedGroupEventLogStore(
                page: try .init(roomID: roomID, events: entries, nextRoomSequence: 8, hasMore: false)
            )),
            sync: fixture.syncService(),
            maximumGroupEventPagePayloadBytes: 2_048
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.pageSize = 8

        var response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.groupEventPage.events.count > 0)
        #expect(response.groupEventPage.events.count < entries.count)
        #expect(response.groupEventPage.hasMore_p)
        #expect(response.groupEventPage.nextRoomSequence == response.groupEventPage.events.last?.roomSequence)

        response.requestID = .max
        response.protocolVersion = IMV2ProtocolVersion.current
        let payload = try V2ServerProtobufFrameCodec.encode(
            response,
            frameVersion: UInt8(IMV2ProtocolVersion.current)
        ).payload
        #expect(payload.count <= 2_048)
    }

    @Test("room-log pulls surface an unencodable durable event as a stable error")
    func groupEventPullReportsUnencodableEvent() async throws {
        let fixture = try GatewayDomainFixture()
        let oversizedEvent = try V2GroupEventLogEntry(
            sourceEventID: try .init("00000000-0000-0000-0000-000000000001"),
            roomSequence: 1,
            projectionKind: "message.accepted",
            payload: Data(repeating: 0x78, count: 2_500)
        )
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            groupEventLog: .init(store: GatewaySizedGroupEventLogStore(
                page: try .init(roomID: fixture.roomID, events: [oversizedEvent], nextRoomSequence: 1, hasMore: false)
            )),
            sync: fixture.syncService(),
            maximumGroupEventPagePayloadBytes: 2_048
        )
        var request = IMV2Envelope()
        request.groupEventPull = .init()
        request.groupEventPull.roomID = fixture.roomID.rawValue
        request.groupEventPull.pageSize = 1

        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "GROUP_EVENT_TOO_LARGE")
        #expect(!response.error.retryable)
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

    @Test("member directory owner changes request a fresh page")
    func membershipDirectoryOwnerChangeRestartsPagination() async throws {
        let fixture = try GatewayDomainFixture()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            membershipDirectory: .init(store: GatewayMovedMembershipDirectory()), sync: fixture.syncService())
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = fixture.roomID.rawValue
        request.listRoomMembers.pageSize = 100
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "REVISION_CONFLICT")
        #expect(response.error.retryable)
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

    @Test("receipt owner change returns retryable unavailability", arguments: ["record", "readers"])
    func readReceiptOwnerChangeIsRetryable(_ kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayOwnerChangedReadReceiptStore()
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            readReceipt: .init(store: store), sync: fixture.syncService())
        var request = IMV2Envelope()
        if kind == "record" {
            request.recordReadReceipt.roomID = fixture.roomID.rawValue
            request.recordReadReceipt.operationID = "00000000-0000-0000-0000-000000000027"
            request.recordReadReceipt.readThroughRoomSequence = 1
        } else {
            request.listReadReceiptReaders.roomID = fixture.roomID.rawValue
            request.listReadReceiptReaders.messageID = "00000000-0000-0000-0000-000000000028"
            request.listReadReceiptReaders.pageSize = 10
        }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        #expect(await store.calls() == [kind])
    }

    @Test("moderation owner changes return retryable unavailability", arguments: ["redact", "mute", "remove"])
    func moderationOwnerChangeIsRetryable(_ kind: String) async throws {
        let fixture = try GatewayDomainFixture()
        let store = GatewayModerationStore(failure: .ownerChanged)
        let handler = makeGatewayDomainCommandHandler(
            sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])),
            moderation: .init(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), now: { fixture.now }),
            sync: fixture.syncService()
        )
        let operation = "00000000-0000-0000-0000-000000000027"
        let target = "00000000-0000-0000-0000-000000000028"
        var request = IMV2Envelope()
        switch kind {
        case "redact":
            request.moderateMessage.roomID = fixture.roomID.rawValue
            request.moderateMessage.operationID = operation
            request.moderateMessage.messageID = target
            request.moderateMessage.reasonCode = "abuse_spam"
        case "mute":
            request.muteMember.roomID = fixture.roomID.rawValue
            request.muteMember.operationID = operation
            request.muteMember.targetUserID = target
            request.muteMember.muteUntilMs = Int64(fixture.now.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
            request.muteMember.reasonCode = "abuse_spam"
        default:
            request.moderateMemberRemoval.roomID = fixture.roomID.rawValue
            request.moderateMemberRemoval.operationID = operation
            request.moderateMemberRemoval.targetUserID = target
            request.moderateMemberRemoval.reasonCode = "abuse_spam"
        }
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        #expect(response.error.code == "UNAVAILABLE" && response.error.retryable)
        #expect(await store.actor() == fixture.userID)
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

private struct GatewayResponseAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: nil)
    }
}

private actor GatewayAccountStartProbe: V2AccountRoomChangesStarting {
    let epoch = UUID()
    private(set) var connectionID: UUID?
    private(set) var userID: UserID?
    func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String {
        self.connectionID = connectionID
        self.userID = userID
        return epoch.uuidString
    }
}

private actor GatewayRecoveryProbe: V2RoomRecoveryCommandHandling {
    private(set) var actor: UserID?
    let failure: V2RoomRecoveryReadError?
    init(failure: V2RoomRecoveryReadError? = nil) { self.failure = failure }
    func list(_ request: IMV2UserRoomDirectoryList, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.userRoomDirectoryPage = .init()
        return response
    }
    func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.roomLatestVisibleBatchResult = .init()
        return response
    }
    func batch(_ request: IMV2RoomSyncStateBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        actor = actorUserID
        if let failure { throw failure }
        var response = IMV2Envelope()
        response.roomSyncStateBatchResult = .init()
        return response
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
        profile = try .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 7)
        roomState = try .init(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10)))
        shardState = try .init(lease: .init(id: try .init("00000000-0000-0000-0000-000000000015"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10)))
    }

    var identity: V2AuthenticatedConnection { .init(userID: userID, deviceID: deviceID, capabilityProfile: "base") }

    func sendService(store: any V2RoomWriteStore) -> V2SendMessageService {
        V2SendMessageService(store: store, capacityProfile: try! .init(id: "standard", limits: profile), limits: try! .init(maxUTF8Bytes: 16), now: { now })
    }

    func syncService() -> V2SyncService { .init(store: GatewayRejectingSyncStore()) }
}

private actor GatewaySnapshotClockStore: V2SyncStore {
    let snapshotID = SnapshotID(uuid: UUID())
    var calls = 0
    private var retryAfter: Double?
    private var expiresAt: Date

    init(retryAfter: Double? = nil, expiresAt: Date = Date(timeIntervalSince1970: 0)) {
        self.retryAfter = retryAfter
        self.expiresAt = expiresAt
    }

    func setRetryAfter(_ value: Double) { retryAfter = value }
    func setExpiry(_ value: Date) { expiresAt = value }

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool, now _: Date) -> V2SyncPullResult {
        calls += 1
        if let retryAfter { return .resetPreparing(snapshotID: snapshotID, generation: 1, retryAfter: retryAfter) }
        return .resetRequired(snapshotID: snapshotID, generation: 1, baseSequence: 7, expiresAt: expiresAt)
    }

    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, now _: Date) throws -> V2SnapshotManifest {
        calls += 1
        return try .init(snapshotID: snapshotID, generation: generation, baseSequence: 7,
            rootDigest: "fixture-digest", schemaVersion: 1, capabilityProfile: "base",
            pageCount: 0, totalItems: 0, totalBytes: 0,
            nextSyncToken: .init("fixture-sync-token"), receipt: .init("fixture-sync-receipt"), expiresAt: expiresAt)
    }

    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) throws -> V2SnapshotPage {
        throw CancellationError()
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
}

private struct GatewayRejectingSyncStore: V2SyncStore {
    var onPull: @Sendable (UserID, DeviceID, Bool) -> Void = { _, _, _ in }

    func pull(userID: UserID, deviceID: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool, now _: Date) async throws -> V2SyncPullResult {
        onPull(userID, deviceID, requireSnapshot)
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

private actor GatewaySyncBoundaryStore: V2SyncStore {
    let snapshotID = SnapshotID(uuid: UUID())
    var calls = 0
    var lastGeneration: UInt64?
    var lastSequence: UInt64?

    private func record(generation: UInt64, sequence: UInt64? = nil) throws {
        calls += 1
        lastGeneration = generation
        lastSequence = sequence
        // Mirror the persistence range so the test also catches a request
        // error being misreported as a retryable server failure.
        guard Int64(exactly: generation) != nil,
              sequence.map({ Int64(exactly: $0) != nil }) ?? true else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard generation > 0 else { throw V2SyncStoreError.generationMismatch }
    }
    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool, now _: Date) throws -> V2SyncPullResult { throw CancellationError() }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        try record(generation: generation, sequence: highestContiguousSequence)
    }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) throws -> V2SnapshotManifest {
        try record(generation: generation)
        return try .init(snapshotID: snapshotID, generation: generation, baseSequence: 0, rootDigest: "boundary-root",
            schemaVersion: V2SnapshotProjectionV3Codec.schemaVersion, capabilityProfile: "base", pageCount: 1,
            totalItems: 1, totalBytes: 4, nextSyncToken: .init("boundary-token"), receipt: .init("boundary-receipt"),
            expiresAt: now.addingTimeInterval(60))
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now _: Date) throws -> V2SnapshotPage {
        try record(generation: generation)
        let key = try V2SnapshotProjectionKey(projectionKind: "relationship", entityKey: "boundary-peer")
        return .init(snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index,
            firstKey: key, lastKey: key, itemCount: 1, digest: "page-digest", payload: Data("page".utf8))
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        try record(generation: generation, sequence: baseSequence)
    }
}

private actor GatewayRecoveringSyncStore: V2SyncStore {
    private var failure: V2SyncStoreError?
    var calls = 0

    init(failure: V2SyncStoreError) { self.failure = failure }
    func recover() { failure = nil }

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool, now _: Date) throws -> V2SyncPullResult {
        calls += 1
        if let failure { throw failure }
        if requireSnapshot { return .resetPreparing(snapshotID: .init(uuid: UUID()), generation: 2, retryAfter: 1) }
        return try .ready(generation: 1, records: [], nextSyncToken: .init("recovered-token"), receipt: .init("recovered-receipt"), hasMore: false)
    }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) throws -> V2SnapshotManifest {
        throw CancellationError()
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) throws -> V2SnapshotPage {
        throw CancellationError()
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) throws {
        throw CancellationError()
    }
}

private actor GatewayTimestampSequenceStore: V2RoomWriteStore {
    var outcomes: [V2SendMessageOutcome]
    init(outcomes: [V2SendMessageOutcome]) { self.outcomes = outcomes }
    func accept(command: V2SendMessageCommand, capacityProfile: V2CapacityProfile,
                identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
        guard !outcomes.isEmpty else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return outcomes.removeFirst()
    }
}

private struct GatewayPersonalTimestampFailure: V2ConversationCapabilitiesStore {
    let error: V2ConversationCapabilitiesStoreError
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> { throw error }
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> { throw error }
}

private struct GatewayAcceptedMessageStore: V2RoomWriteStore {
    let outcome: V2SendMessageOutcome
    var beforeReturn: (@Sendable () throws -> Void)? = nil

    func accept(
        command _: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers _: V2AcceptanceIdentifiers,
        now _: Date
    ) async throws -> V2SendMessageOutcome {
        try beforeReturn?()
        return outcome
    }
}

private struct GatewayAtomicBatchStore: V2AtomicRoomWriteBatchStore {
    func accept(
        command _: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers _: V2AcceptanceIdentifiers,
        now _: Date
    ) async throws -> V2SendMessageOutcome {
        .rateLimited(retryAfterSeconds: 1)
    }

    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        requests.map { _ in .rateLimited(retryAfterSeconds: 1) }
    }
}

private struct GatewayPoolTimeoutMessageStore: V2RoomWriteStore {
    func accept(
        command _: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers _: V2AcceptanceIdentifiers,
        now _: Date
    ) async throws -> V2SendMessageOutcome {
        throw ConnectionPoolTimeoutError.connectionRequestTimeout
    }
}

private final class GatewayForegroundHintRecorder:
    V2ForegroundGroupEventHintSubmitting,
    Sendable
{
    private let hints = Mutex<[V2GroupEventWake]>([])
    private let exclusions = Mutex<[UUID?]>([])
    private let membershipRevisions = Mutex<[UInt64?]>([])

    func submitForegroundHint(_ hint: V2GroupEventWake) {
        hints.withLock { $0.append(hint) }
    }

    func submitForegroundDirectMessage(_ message: V2AcceptedMessage) {
        exclusions.withLock { $0.append(nil) }
        submitForegroundHint(.init(
            roomID: message.roomID,
            highWatermark: message.roomSequence
        ))
    }

    func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) {
        exclusions.withLock { $0.append(event.excludedConnectionID) }
        membershipRevisions.withLock { $0.append(event.groupMembershipRevision) }
        submitForegroundHint(.init(
            roomID: event.roomID,
            highWatermark: event.highWatermark
        ))
    }

    func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    ) {
        exclusions.withLock { $0.append(excludingConnectionID) }
        submitForegroundHint(.init(
            roomID: message.roomID,
            highWatermark: message.roomSequence
        ))
    }

    func values() -> [V2GroupEventWake] { hints.withLock { $0 } }
    func groupMembershipRevisions() -> [UInt64] {
        membershipRevisions.withLock { $0.compactMap { $0 } }
    }
    func directExclusions() -> [UUID?] { exclusions.withLock { $0 } }
}

private actor GatewayMembershipStore: V2RoomMembershipStore {
    private var capturedActor: UserID?
    private let failure: V2RoomMembershipStoreError?
    init(failure: V2RoomMembershipStoreError? = nil) { self.failure = failure }

    func change(command: V2ChangeRoomMembershipCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        capturedActor = command.actorUserID
        if let failure { throw failure }
        return .changed(try .init(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action, membershipRevision: command.expectedMembershipRevision + 1, roomSequence: 1, eventID: eventID, createdAt: now))
    }

    func actor() -> UserID? { capturedActor }
}

/// 会话摘要假存储：记录调用者与游标，按构造时给定的单行摘要回答。
///
/// 只要给出水位就返回 `hasMore`，用于验证网关确实把下一页游标发了出去。


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
    private let returnedMemberCount: Int?
    private let replay: Bool
    private var capturedActor: UserID?
    private var capturedMembers: [UserID] = []

    init(returnedMemberCount: Int? = nil, replay: Bool = false) {
        self.returnedMemberCount = returnedMemberCount
        self.replay = replay
    }

    func create(command: V2CreateGroupRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID _: String, roomID: RoomID, eventID _: EventID, now: Date) throws -> V2CreateGroupRoomOutcome {
        capturedActor = command.actorUserID
        capturedMembers = command.allMemberUserIDs
        let room = try V2GroupRoom(roomID: roomID, ownerUserID: command.actorUserID, title: command.title,
            capacityClass: command.capacityClass, memberUserIDs: command.allMemberUserIDs,
            memberCount: returnedMemberCount, createdAt: now)
        return replay ? .idempotent(room) : .created(room)
    }

    func actor() -> UserID? { capturedActor }
    func members() -> [UserID] { capturedMembers }
}

private actor GatewayAudienceImportStore: V2GroupAudienceImportStore {
    private let returnedMemberCount: Int?
    private var capturedActor: UserID?
    private var title: String?
    private var members: [UserID] = []
    private var recoveryCandidates: [V2GroupAudienceRecoveryCandidate] = []
    private var completedOperationIDsValue: [GroupRoomOperationID] = []
    private var failingRecoveryOperationIDs: Set<GroupRoomOperationID> = []
    private var cancellationFrozen = false

    init(returnedMemberCount: Int? = nil) { self.returnedMemberCount = returnedMemberCount }

    func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy _: V2GroupAudienceImportPolicy, now _: Date) throws -> V2GroupAudienceDraft {
        capturedActor = actorUserID
        if let existingTitle = self.title {
            guard existingTitle == title else { throw V2GroupAudienceImportError.idempotencyConflict }
        } else {
            self.title = title
        }
        return .init(operationID: operationID, title: title, stagedMemberCount: returnedMemberCount ?? members.count)
    }

    func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy _: V2GroupAudienceImportPolicy, now _: Date) throws -> V2GroupAudienceDraft {
        capturedActor = actorUserID
        guard let title else { throw V2GroupAudienceImportError.missingDraft }
        members = Array(Set(members).union(memberUserIDs)).sorted()
        guard members.count <= maximumMembers else { throw V2GroupAudienceImportError.memberLimitReached }
        return .init(operationID: operationID, title: title, stagedMemberCount: returnedMemberCount ?? members.count)
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
        try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: false)
    }

    func subscribe(roomID: RoomID, actorUserID: UserID) throws -> V2GroupEventSubscription {
        capturedActor = actorUserID
        return try .init(roomID: roomID, highWatermark: 91)
    }

    func actor() -> UserID? { capturedActor }
}

private struct GatewaySizedGroupEventLogStore: V2GroupEventLogStore {
    let page: V2GroupEventLogPage

    func pull(roomID _: RoomID, actorUserID _: UserID, afterRoomSequence _: UInt64, pageSize _: Int) async throws -> V2GroupEventLogPage {
        page
    }

    func subscribe(roomID: RoomID, actorUserID _: UserID) async throws -> V2GroupEventSubscription {
        try .init(roomID: roomID, highWatermark: page.nextRoomSequence)
    }
}

private actor GatewayModerationStore: V2ModerationStore {
    private var capturedActor: UserID?
    private let failure: V2RoomOwnerFenceError?
    init(failure: V2RoomOwnerFenceError? = nil) { self.failure = failure }
    func actor() -> UserID? { capturedActor }
    func apply(command: V2ModerationCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2ModerationOutcome {
        capturedActor = command.actorUserID
        if let failure { throw failure }
        return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: command.targetUserID, messageID: command.messageID, messageRevision: command.action == .redactMessage ? 2 : nil, membershipRevision: command.action == .removeMember ? 4 : nil, muteUntil: command.muteUntil, roomSequence: 3, eventID: eventID, createdAt: now))
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

private actor GatewayOwnerChangedMutationStore: V2MessageEditStore, V2MessageWithdrawalStore, V2MessageReactionStore {
    private var received: [String] = []
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageEditOutcome {
        received.append("edit")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageWithdrawalOutcome {
        received.append("withdraw")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageReactionOutcome {
        received.append("reaction")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func calls() -> [String] { received }
}

private actor GatewayRevisionBoundaryStore: V2RoomMembershipStore, V2MessageEditStore, V2MessageWithdrawalStore {
    private var count = 0
    private let conflictRevision: UInt64?
    init(conflictRevision: UInt64? = nil) { self.conflictRevision = conflictRevision }
    func change(command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        count += 1
        if let conflictRevision { return .revisionConflict(current: conflictRevision) }
        return .targetAlreadyMember
    }
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) -> V2MessageEditOutcome {
        count += 1
        if let conflictRevision { return .revisionConflict(current: conflictRevision) }
        return .alreadyWithdrawn
    }
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) -> V2MessageWithdrawalOutcome {
        count += 1
        if let conflictRevision { return .revisionConflict(current: conflictRevision) }
        return .alreadyWithdrawn
    }
    func calls() -> Int { count }
}

private struct GatewayPendingForward: V2ForwardMessagesHandling {
    let paused: Bool
    func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        throw paused ? V2ForwardPendingError.paused : V2ForwardPendingError.pending
    }
}

extension V2GatewayDomainCommandHandlerTests {
    @Test("policy baseline uses authenticated identity and emits both roles including empty")
    func groupRolePolicyBaselineWire() async throws {
        let fixture = try GatewayDomainFixture()
        let reader = GatewayPolicyBaselineReader(scenario: "valid")
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])), groupRolePolicyBaseline: reader, sync: fixture.syncService())
        var request = IMV2Envelope(); request.requestID = 10; request.protocolVersion = IMV2ProtocolVersion.current
        request.getGroupRolePolicyBaseline.roomID = fixture.roomID.rawValue
        let decoded = try V2ServerProtobufFrameCodec.decode(V2ServerProtobufFrameCodec.encode(request, frameVersion: UInt8(IMV2ProtocolVersion.current)))
        let response = try await handler.handle(envelope: decoded, identity: fixture.identity)
        #expect(response.groupRolePolicyBaseline.roomID == fixture.roomID.rawValue)
        #expect(response.groupRolePolicyBaseline.permissionRevision == 4)
        #expect(response.groupRolePolicyBaseline.membershipRevision == 0)
        #expect(response.groupRolePolicyBaseline.policies.map(\.role) == ["admin", "member"])
        #expect(response.groupRolePolicyBaseline.policies[0].permissions.map(\.permission) == ["invite_members"])
        #expect(response.groupRolePolicyBaseline.policies[1].permissions.isEmpty)
        #expect(await reader.calls() == [.init(room: fixture.roomID, actor: fixture.userID)])
    }

    @Test("policy baseline failures have stable protocol errors", arguments: ["forbidden", "notFound", "ownerChanged", "unavailable", "wrongRoom", "invalid"])
    func groupRolePolicyBaselineErrors(scenario: String) async throws {
        let fixture = try GatewayDomainFixture()
        let reader = GatewayPolicyBaselineReader(scenario: scenario)
        let handler = makeGatewayDomainCommandHandler(sendMessage: fixture.sendService(store: InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.userID])), groupRolePolicyBaseline: reader, sync: fixture.syncService())
        var request = IMV2Envelope(); request.getGroupRolePolicyBaseline.roomID = scenario == "invalid" ? "invalid" : fixture.roomID.rawValue
        let response = try await handler.handle(envelope: request, identity: fixture.identity)
        let code = switch scenario { case "forbidden": "FORBIDDEN"; case "notFound": "NOT_FOUND"; case "ownerChanged": "ROOM_OWNER_CHANGED"; case "invalid": "INVALID_ARGUMENT"; default: "UNAVAILABLE" }
        #expect(response.error.code == code)
        #expect(response.error.retryable == ["ownerChanged", "unavailable", "wrongRoom"].contains(scenario))
        if scenario == "invalid" { #expect(await reader.calls().isEmpty) }
    }
}

private actor GatewayPolicyBaselineReader: V2GroupRolePolicyBaselineReading {
    struct Call: Equatable { let room: RoomID; let actor: UserID }
    let scenario: String
    private var values: [Call] = []
    init(scenario: String) { self.scenario = scenario }
    func calls() -> [Call] { values }
    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) throws -> V2GroupRolePolicyBaseline {
        values.append(.init(room: roomID, actor: actorUserID))
        switch scenario {
        case "forbidden": throw V2GroupRolePolicyBaselineError.actorNotMember
        case "notFound": throw V2GroupRolePolicyBaselineError.roomNotFound
        case "ownerChanged": throw V2RoomShardRouteError.routeConflict
        case "unavailable": throw V2GroupRolePolicyBaselineError.corruptPersistenceState
        default: break
        }
        return try .init(roomID: scenario == "wrongRoom" ? .init("00000000-0000-0000-0000-000000ABCDEF") : roomID, permissionRevision: 4, membershipRevision: 0, roomSequence: 9, adminPermissions: [.inviteMembers], memberPermissions: [])
    }
}

private actor GatewayOwnerChangedGroupCapabilityStore: V2GroupCapabilitiesStore {
    private var received: [String] = []
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        received.append("pin")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        received.append("announcement")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        received.append("permissions")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        received.append("role")
        throw V2RoomOwnerFenceError.ownerChanged
    }
    func calls() -> [String] { received }
}

private actor GatewayOwnerChangedReadReceiptStore: V2ReadReceiptStore {
    private var received: [String] = []
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome { received.append("record"); throw V2ReadReceiptStoreError.ownerChanged }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { received.append("readers"); throw V2ReadReceiptStoreError.ownerChanged }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) throws -> V2SetReadReceiptPreferencesOutcome { throw V2ReadReceiptStoreError.ownerChanged }
    func calls() -> [String] { received }
}

private struct GatewayOwnerChangedSendStore: V2RoomWriteStore {
    func accept(command: V2SendMessageCommand, capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
        throw V2RoomOwnerFenceError.ownerChanged
    }
}

private struct GatewayGroupIntentClockFailure: V2GroupMessagingStore {
    func create(command: V2CreateGroupRoomCommand, capacityProfile: V2CapacityProfile,
                roomShardID: String, roomID: RoomID, eventID: EventID, now: Date) async throws -> V2CreateGroupRoomOutcome {
        throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
    }
}

// Returns domain outputs directly so response encoding is exercised independently of storage validation.
private actor GatewayResponseClockStore: V2RoomMembershipStore, V2ModerationStore, V2SocialRelationshipStore,
    V2ReadReceiptStore, V2DirectMessagingStore, V2LiveActivityStore, V2MessageEditStore, V2MessageWithdrawalStore, V2MessageReactionStore,
    V2ConversationCapabilitiesStore, V2GroupCapabilitiesStore, V2GroupMessagingStore {
    private var date: Date
    private var replay: Bool
    private let muteExpiryOnly: Bool
    private(set) var calls = 0
    init(date: Date, replay: Bool, muteExpiryOnly: Bool) { self.date = date; self.replay = replay; self.muteExpiryOnly = muteExpiryOnly }
    func recover(at date: Date) { self.date = date; replay = true }
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) -> V2ConversationCapabilitiesOutcome<V2ConversationState> {
        calls += 1
        let value = V2ConversationState(roomID: command.roomID, isPinned: command.isPinned, isArchived: command.isArchived,
            muteUntil: muteExpiryOnly ? date : nil, updatedAt: muteExpiryOnly ? now : date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> {
        calls += 1
        let value = V2MessageFavorite(roomID: command.roomID, messageID: command.messageID, isFavorited: command.isFavorited, updatedAt: date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        calls += 1
        let value = try V2PinnedMessage(roomID: command.roomID, messageID: command.messageID, isPinned: command.isPinned, roomSequence: 3, updatedAt: date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        calls += 1
        let value = try V2GroupAnnouncement(roomID: command.roomID, body: command.body, revision: 2, roomSequence: 3, updatedAt: date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> { throw CancellationError() }
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> { throw CancellationError() }
    func create(command: V2CreateGroupRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, eventID: EventID, now: Date) throws -> V2CreateGroupRoomOutcome {
        calls += 1
        let value = try V2GroupRoom(roomID: roomID, ownerUserID: command.actorUserID, title: command.title,
            capacityClass: command.capacityClass, memberUserIDs: command.allMemberUserIDs, createdAt: date)
        return replay ? .idempotent(value) : .created(value)
    }
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageEditOutcome {
        calls += 1
        let value = try V2MessageEdit(roomID: command.roomID, messageID: command.messageID, text: command.text,
            messageRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .edited(value)
    }
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageWithdrawalOutcome {
        calls += 1
        let value = try V2MessageWithdrawal(roomID: command.roomID, messageID: command.messageID,
            messageRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .withdrawn(value)
    }
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageReactionOutcome {
        calls += 1
        let value = try V2MessageReactionChange(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID,
            reaction: command.reaction, action: command.action, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func change(command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        calls += 1
        let value = try V2RoomMembershipChange(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action,
            membershipRevision: 2, roomSequence: 3, eventID: eventID, createdAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2ModerationOutcome {
        calls += 1
        let value = try V2ModerationResult(roomID: command.roomID, operationID: command.operationID, action: command.action,
            targetUserID: command.targetUserID, messageID: command.messageID, messageRevision: command.action == .redactMessage ? 2 : nil,
            membershipRevision: command.action == .removeMember ? 2 : nil, muteUntil: muteExpiryOnly ? date : command.muteUntil,
            roomSequence: 3, eventID: eventID, createdAt: muteExpiryOnly ? now : date)
        return replay ? .idempotent(value) : .applied(value)
    }
    func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) -> V2RelationshipOutcome {
        calls += 1
        let value = V2RelationshipChange(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, resultingState: .pending, updatedAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) -> V2UserBlockOutcome {
        calls += 1
        let value = V2UserBlockChange(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, isBlocked: true, updatedAt: date)
        return replay ? .idempotent(value) : .changed(value)
    }
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        calls += 1
        let value = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: date)
        return replay ? .idempotent(value) : .recorded(value)
    }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) -> V2SetReadReceiptPreferencesOutcome {
        calls += 1
        let value = V2ReadReceiptPreferences(allowsDirectReadReceipts: command.allowsDirectReadReceipts, allowsGroupReadReceipts: command.allowsGroupReadReceipts, updatedAt: date)
        return replay ? .idempotent(value) : .updated(value)
    }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { throw CancellationError() }
    func open(command: V2OpenDirectRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, now: Date) -> V2OpenDirectRoomOutcome {
        calls += 1
        let value = V2DirectRoom(roomID: roomID, actorUserID: command.actorUserID, targetUserID: command.targetUserID, createdAt: date)
        return replay ? .idempotent(value) : .opened(value)
    }
    func setStrangerMessagePermission(command: V2SetStrangerMessagePermissionCommand, now: Date) -> V2SetStrangerMessagePermissionOutcome {
        calls += 1
        return replay ? .idempotent(permission: command.permission, updatedAt: date) : .updated(permission: command.permission, updatedAt: date)
    }
    func setUserAddPermission(command: V2SetUserAddPermissionCommand, now: Date) -> V2SetUserAddPermissionOutcome {
        calls += 1
        return replay ? .idempotent(permission: command.permission, updatedAt: date) : .updated(permission: command.permission, updatedAt: date)
    }
    func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) -> V2SetLiveActivityPreferencesOutcome {
        calls += 1
        let value = V2LiveActivityPreferences(allowsOnlinePresence: command.allowsOnlinePresence, allowsTypingIndicators: command.allowsTypingIndicators, updatedAt: date)
        return replay ? .idempotent(value) : .updated(value)
    }
    func preferences(userID: UserID, now: Date) -> V2LiveActivityPreferences {
        calls += 1
        return .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: date)
    }
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) -> V2PresenceState {
        calls += 1
        return .init(roomID: roomID, targetUserID: .init(uuid: UUID()), isOnline: true, expiresAt: date)
    }
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) throws { throw CancellationError() }
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) throws { throw CancellationError() }
    func allowsOnlinePresence(userID: UserID) throws -> Bool { throw CancellationError() }
}

private actor GatewayReadReceiptSequenceStore: V2ReadReceiptStore {
    private(set) var calls = 0
    private var receipt: V2ReadReceipt?
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        calls += 1
        // Model the PostgreSQL adapter's existing signed binding boundary.
        guard Int64(exactly: command.readThroughRoomSequence) != nil else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        if let receipt { return .idempotent(receipt) }
        let value = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID,
            readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: now)
        receipt = value
        return .recorded(value)
    }
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) throws -> V2SetReadReceiptPreferencesOutcome { throw CancellationError() }
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage { throw CancellationError() }
}

private struct GatewayForwardSequence: V2ForwardMessagesHandling {
    let sequence: UInt64
    let failed: Bool
    func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        [try .init(sourceMessageID: command.sources[0].messageID, targetRoomID: command.targetRoomIDs[0],
               messageID: failed ? nil : command.sources[0].messageID,
               roomSequence: failed ? nil : sequence, errorCode: failed ? "FORBIDDEN" : nil)]
    }
}

private struct GatewayMovedMembershipDirectory: V2RoomMembershipDirectoryStore {
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        throw V2RoomMembershipDirectoryError.ownerChanged
    }
}
