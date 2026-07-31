import Foundation
import IMV2Core

/// Routes validated authenticated protobuf commands to the V2 domain services.
public struct V2GatewayDomainCommandHandler: V2GatewayCommandHandler {
    private let sendMessage: V2SendMessageService
    private let membership: V2RoomMembershipService?
    private let withdrawal: V2MessageWithdrawalService?
    private let reaction: V2MessageReactionService?
    private let edit: V2MessageEditService?
    private let readReceipt: V2ReadReceiptService?
    private let directMessaging: V2DirectMessagingService?
    private let groupMessaging: V2GroupMessagingService?
    private let groupAudienceImports: V2GroupAudienceImportService?
    private let groupEventLog: V2GroupEventLogService?
    private let foregroundGroupEventHints: any V2ForegroundGroupEventHintPublishing
    private let membershipDirectory: V2RoomMembershipDirectoryService?
    private let socialRelationships: V2SocialRelationshipService?
    private let moderation: V2ModerationService?
    private let sync: V2SyncService
    private let telemetry: any V2TelemetrySink
    private let now: @Sendable () -> Date

    public init(sendMessage: V2SendMessageService, membership: V2RoomMembershipService? = nil, withdrawal: V2MessageWithdrawalService? = nil, reaction: V2MessageReactionService? = nil, edit: V2MessageEditService? = nil, readReceipt: V2ReadReceiptService? = nil, directMessaging: V2DirectMessagingService? = nil, groupMessaging: V2GroupMessagingService? = nil, groupAudienceImports: V2GroupAudienceImportService? = nil, groupEventLog: V2GroupEventLogService? = nil, foregroundGroupEventHints: any V2ForegroundGroupEventHintPublishing = V2NoopForegroundGroupEventHintPublisher(), membershipDirectory: V2RoomMembershipDirectoryService? = nil, socialRelationships: V2SocialRelationshipService? = nil, moderation: V2ModerationService? = nil, sync: V2SyncService, telemetry: any V2TelemetrySink = V2NoopTelemetrySink(), now: @escaping @Sendable () -> Date = Date.init) {
        self.sendMessage = sendMessage
        self.membership = membership
        self.withdrawal = withdrawal
        self.reaction = reaction
        self.edit = edit
        self.readReceipt = readReceipt
        self.directMessaging = directMessaging
        self.groupMessaging = groupMessaging
        self.groupAudienceImports = groupAudienceImports
        self.groupEventLog = groupEventLog
        self.foregroundGroupEventHints = foregroundGroupEventHints
        self.membershipDirectory = membershipDirectory
        self.socialRelationships = socialRelationships
        self.moderation = moderation
        self.sync = sync
        self.telemetry = telemetry
        self.now = now
    }

    public func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let traceID = UUID()
        let command = v2TelemetryCommand(for: envelope)
        let startedAt = now()
        do {
            let response = try await handleWithoutTelemetry(envelope: envelope, identity: identity)
            let hasProtocolError: Bool
            let rejection: V2GatewayTelemetryRejection?
            if case .error(let error) = response.body {
                hasProtocolError = true
                rejection = .init(protocolCode: error.code)
            } else {
                hasProtocolError = false
                rejection = nil
            }
            await telemetry.record(.gatewayCommand(
                traceID: traceID,
                command: command,
                // A future protocol error may intentionally have no metric
                // label until it is reviewed. It is still a rejection, never
                // an accepted command merely because it is unclassified.
                outcome: hasProtocolError ? .rejected : .accepted,
                rejection: rejection,
                elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())
            ))
            return response
        } catch {
            await telemetry.record(.gatewayCommand(
                traceID: traceID,
                command: command,
                outcome: .failed,
                rejection: nil,
                elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())
            ))
            throw error
        }
    }

    private func handleWithoutTelemetry(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        do {
            switch envelope.body {
            case .sendMessage(let request): return try await handleSend(request, identity: identity)
            case .changeRoomMembership(let request): return try await handleMembership(request, identity: identity)
            case .withdrawMessage(let request): return try await handleWithdrawal(request, identity: identity)
            case .changeMessageReaction(let request): return try await handleReaction(request, identity: identity)
            case .editMessage(let request): return try await handleEdit(request, identity: identity)
            case .recordReadReceipt(let request): return try await handleReadReceipt(request, identity: identity)
            case .openDirectRoom(let request): return try await handleOpenDirectRoom(request, identity: identity)
            case .createGroupRoom(let request): return try await handleCreateGroupRoom(request, identity: identity)
            case .beginGroupRoomCreation(let request): return try await handleBeginGroupRoomCreation(request, identity: identity)
            case .appendGroupRoomCreationMembers(let request): return try await handleAppendGroupRoomCreationMembers(request, identity: identity)
            case .finalizeGroupRoomCreation(let request): return try await handleFinalizeGroupRoomCreation(request, identity: identity)
            case .cancelGroupRoomCreation(let request): return try await handleCancelGroupRoomCreation(request, identity: identity)
            case .listRoomMembers(let request): return try await handleListRoomMembers(request, identity: identity)
            case .groupEventPull(let request): return try await handleGroupEventPull(request, identity: identity)
            case .groupEventSubscribe(let request): return try await handleGroupEventSubscribe(request, identity: identity)
            case .groupEventUnsubscribe: return successEnvelope()
            case .setStrangerMessagePermission(let request): return try await handleStrangerMessagePermission(request, identity: identity)
            case .setUserAddPermission(let request): return try await handleUserAddPermission(request, identity: identity)
            case .changeRelationship(let request): return try await handleRelationship(request, identity: identity)
            case .changeUserBlock(let request): return try await handleUserBlock(request, identity: identity)
            case .moderateMessage(let request): return try await handleModerateMessage(request, identity: identity)
            case .muteMember(let request): return try await handleMuteMember(request, identity: identity)
            case .moderateMemberRemoval(let request): return try await handleModerateMemberRemoval(request, identity: identity)
            case .syncPull(let request): return try await handlePull(request, identity: identity)
            case .syncAck(let request):
                try await sync.acknowledge(userID: identity.userID, deviceID: identity.deviceID, generation: request.generation, highestContiguousSequence: request.highestContiguousSequence, receipt: try .init(request.syncReceipt))
                return successEnvelope()
            case .syncSnapshot(let request): return try await handleSnapshotManifest(request, identity: identity)
            case .snapshotPagePull(let request): return try await handleSnapshotPage(request, identity: identity)
            case .snapshotAck(let request):
                try await sync.acknowledgeSnapshot(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation, baseSequence: request.baseUserSyncSequence, receipt: try .init(request.snapshotReceipt))
                return successEnvelope()
            default: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
            }
        } catch V2CoreError.invalidIdentifier, V2SendMessageValidationError.invalidTextLength, V2MediaStoreError.invalidReferenceSet, V2MentionValidationError.invalidLimits, V2MentionValidationError.invalidTargetSet, V2ModerationValidationError.invalidReasonCode, V2ModerationValidationError.invalidActionShape, V2ModerationValidationError.invalidMuteExpiry, V2RoomMembershipValidationError.selfTargetingNotAllowed, V2DirectMessagingValidationError.selfTargetingNotAllowed, V2SocialRelationshipValidationError.selfTargetingNotAllowed, V2MessageReactionValidationError.invalidReaction, V2MessageEditValidationError.invalidText, V2ReadReceiptValidationError.invalidRoomSequence, V2GroupMessagingValidationError.invalidTitle, V2GroupMessagingValidationError.invalidInitialMembers, V2GroupAudienceImportError.invalidInput, V2RoomMembershipDirectoryError.invalidRequest, V2RoomMembershipDirectoryError.invalidCursor, V2GroupEventLogError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupAudienceImportError.memberLimitReached, V2GroupAudienceImportError.activeDraftLimitReached {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupAudienceImportError.missingDraft {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2GroupAudienceImportError.draftFrozen {
            return errorEnvelope(code: "GROUP_CREATION_FROZEN", retryable: false)
        } catch V2GroupAudienceImportError.idempotencyConflict {
            return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        } catch V2GroupAudienceImportError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomMembershipStoreError.actorNotOwner {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2RoomMembershipDirectoryError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2GroupEventLogError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2SocialRelationshipStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted, V2RoomWriteStoreError.roomFrozen, V2RoomWriteStoreError.directMessageBlocked, V2RoomWriteStoreError.strangerMessagePermissionDenied {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MentionValidationError.notAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationAuthorizationError.notAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired, V2MediaStoreError.invalidStateTransition {
            return errorEnvelope(code: "MEDIA_UNAVAILABLE", retryable: false)
        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
            return errorEnvelope(code: "RATE_LIMITED", retryable: true)
        } catch V2RoomMembershipStoreError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomMembershipDirectoryError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2GroupEventLogError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageWithdrawalStoreError.roomNotFound, V2MessageWithdrawalStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageWithdrawalStoreError.actorNotAuthor {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationStoreError.roomNotFound, V2ModerationStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ModerationStoreError.actorNotAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationStoreError.unsupportedAction {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2MessageEditStoreError.roomNotFound, V2MessageEditStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageEditStoreError.actorNotAuthor {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ReadReceiptStoreError.roomNotFound, V2ReadReceiptStoreError.roomSequenceNotFound {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2ReadReceiptStoreError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MessageReactionStoreError.roomNotFound, V2MessageReactionStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageReactionStoreError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MessageReactionStoreError.messageWithdrawn {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2SyncStoreError.invalidOrExpiredSyncToken {
            // A token is only an opaque continuation capability.  Its expiry
            // is not a transport failure: the client can restart its pull
            // from its durable cursor without reconnecting.
            return errorEnvelope(code: "SYNC_TOKEN_INVALID", retryable: false)
        } catch V2SyncStoreError.invalidOrExpiredSyncReceipt {
            // ACK receipts fence an individual pull range.  Do not let a
            // stale receipt advance a cursor, and make the retry path
            // explicit to the client rather than surfacing a store error.
            return errorEnvelope(code: "SYNC_RECEIPT_INVALID", retryable: false)
        } catch V2SyncStoreError.resetRequired, V2SyncStoreError.generationMismatch {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.snapshotExpiredOrInvalid, V2SyncStoreError.snapshotFenceMismatch, V2SyncStoreError.noResetPending {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.acknowledgementBeyondWatermark {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
    }

    private func handleSend(_ request: IMV2SendMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.hasContent,
              UUID(uuidString: request.roomID) != nil,
              UUID(uuidString: request.clientMessageID) != nil
        else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let text: String
        switch request.content.body {
        case .text(let value): text = value
        case nil: text = ""
        }
        let media = try request.content.mediaIds.map { try V2MediaReference(mediaID: .init($0)) }
        var mentions = try request.content.mentionedUserIds.map { try V2MentionTarget.user(.init($0)) }
        if request.content.mentionEveryone { mentions.append(.everyone) }
        let outcome = try await sendMessage.send(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, clientMessageID: try .init(request.clientMessageID), text: text, media: media, mentions: mentions))
        switch outcome {
        case .accepted(let message):
            if message.groupDeliveryMode != nil {
                await foregroundGroupEventHints.publishForegroundHint(.init(roomID: message.roomID, highWatermark: message.roomSequence))
            }
            return acceptedMessageEnvelope(message)
        case .idempotent(let message):
            return acceptedMessageEnvelope(message)
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func acceptedMessageEnvelope(_ message: V2AcceptedMessage) -> IMV2Envelope {
            var response = IMV2Envelope(); response.messageAccepted = .init()
            response.messageAccepted.messageID = message.messageID.rawValue
            response.messageAccepted.roomID = message.roomID.rawValue
            response.messageAccepted.roomSequence = message.roomSequence
            response.messageAccepted.serverCreatedAtMs = Int64(message.createdAt.timeIntervalSince1970 * 1_000)
            response.messageAccepted.mediaIds = message.media.map { $0.mediaID.rawValue }
            response.messageAccepted.mentionedUserIds = message.mentions.compactMap { if case .user(let userID) = $0 { userID.rawValue } else { nil } }
            response.messageAccepted.mentionsEveryone = message.mentions.contains(.everyone)
            return response
    }

    private func handleMembership(_ request: IMV2ChangeRoomMembership, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let membership else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let action: V2RoomMembershipAction
        switch request.action {
        case .add: action = .add
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        let outcome = try await membership.change(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            targetUserID: try .init(request.targetUserID),
            action: action,
            expectedMembershipRevision: request.expectedMembershipRevision
        ))
        switch outcome {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.membershipChanged = .init()
            response.membershipChanged.roomID = change.roomID.rawValue
            response.membershipChanged.targetUserID = change.targetUserID.rawValue
            response.membershipChanged.action = change.action == .add ? .add : .remove
            response.membershipChanged.membershipRevision = change.membershipRevision
            response.membershipChanged.roomSequence = change.roomSequence
            response.membershipChanged.serverCreatedAtMs = Int64(change.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .targetAlreadyMember, .targetNotMember, .memberLimitReached: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleWithdrawal(_ request: IMV2WithdrawMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let withdrawal else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let outcome = try await withdrawal.withdraw(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), expectedMessageRevision: request.expectedMessageRevision))
        switch outcome {
        case .withdrawn(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageWithdrawn = .init()
            response.messageWithdrawn.roomID = result.roomID.rawValue
            response.messageWithdrawn.messageID = result.messageID.rawValue
            response.messageWithdrawn.messageRevision = result.messageRevision
            response.messageWithdrawn.roomSequence = result.roomSequence
            response.messageWithdrawn.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .alreadyWithdrawn: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleModerateMessage(_ request: IMV2ModerateMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let moderation else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let outcome = try await moderation.apply(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), action: .redactMessage, messageID: try .init(request.messageID), reasonCode: try .init(request.reasonCode)))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageRedacted = .init()
            response.messageRedacted.roomID = result.roomID.rawValue
            guard let messageID = result.messageID, let messageRevision = result.messageRevision else { throw V2ModerationStoreError.corruptPersistenceState }
            response.messageRedacted.messageID = messageID.rawValue
            response.messageRedacted.roomSequence = result.roomSequence
            response.messageRedacted.messageRevision = messageRevision
            response.messageRedacted.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .messageAlreadyRedacted, .targetNotMember, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleMuteMember(_ request: IMV2MuteMember, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let moderation else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        guard request.muteUntilMs > 0 else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let outcome = try await moderation.apply(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            action: .muteMember,
            targetUserID: try .init(request.targetUserID),
            muteUntil: Date(timeIntervalSince1970: TimeInterval(request.muteUntilMs) / 1_000),
            reasonCode: try .init(request.reasonCode)
        ))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            guard result.action == .muteMember, let targetUserID = result.targetUserID,
                  let muteUntil = result.muteUntil
            else { throw V2ModerationStoreError.corruptPersistenceState }
            var response = IMV2Envelope(); response.memberMuted = .init()
            response.memberMuted.roomID = result.roomID.rawValue
            response.memberMuted.targetUserID = targetUserID.rawValue
            response.memberMuted.muteUntilMs = Int64(muteUntil.timeIntervalSince1970 * 1_000)
            response.memberMuted.roomSequence = result.roomSequence
            response.memberMuted.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .targetNotMember, .messageAlreadyRedacted, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleModerateMemberRemoval(_ request: IMV2ModerateMemberRemoval, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let moderation else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let outcome = try await moderation.apply(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            action: .removeMember,
            targetUserID: try .init(request.targetUserID),
            reasonCode: try .init(request.reasonCode)
        ))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            guard result.action == .removeMember, let targetUserID = result.targetUserID,
                  let membershipRevision = result.membershipRevision
            else { throw V2ModerationStoreError.corruptPersistenceState }
            var response = IMV2Envelope(); response.memberRemovedByModerator = .init()
            response.memberRemovedByModerator.roomID = result.roomID.rawValue
            response.memberRemovedByModerator.targetUserID = targetUserID.rawValue
            response.memberRemovedByModerator.membershipRevision = membershipRevision
            response.memberRemovedByModerator.roomSequence = result.roomSequence
            response.memberRemovedByModerator.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .targetNotMember, .messageAlreadyRedacted, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleReaction(_ request: IMV2ChangeMessageReaction, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let reaction else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let action: V2MessageReactionAction
        switch request.action {
        case .add: action = .add
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        let outcome = try await reaction.change(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), reaction: request.reaction, action: action))
        switch outcome {
        case .changed(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageReactionChanged = .init()
            response.messageReactionChanged.roomID = result.roomID.rawValue
            response.messageReactionChanged.messageID = result.messageID.rawValue
            response.messageReactionChanged.actorUserID = result.actorUserID.rawValue
            response.messageReactionChanged.reaction = result.reaction
            response.messageReactionChanged.action = result.action == .add ? .add : .remove
            response.messageReactionChanged.roomSequence = result.roomSequence
            response.messageReactionChanged.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleEdit(_ request: IMV2EditMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let edit, request.hasContent, case .text(let text)? = request.content.body else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let outcome = try await edit.edit(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), expectedMessageRevision: request.expectedMessageRevision, text: text))
        switch outcome {
        case .edited(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageEdited = .init()
            response.messageEdited.roomID = result.roomID.rawValue
            response.messageEdited.messageID = result.messageID.rawValue
            response.messageEdited.text = result.text
            response.messageEdited.messageRevision = result.messageRevision
            response.messageEdited.roomSequence = result.roomSequence
            response.messageEdited.serverCreatedAtMs = Int64(result.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .alreadyWithdrawn: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleReadReceipt(_ request: IMV2RecordReadReceipt, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let readReceipt else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let outcome = try await readReceipt.record(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), readThroughRoomSequence: request.readThroughRoomSequence))
        switch outcome {
        case .recorded(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.readReceiptRecorded = .init()
            response.readReceiptRecorded.roomID = result.roomID.rawValue
            response.readReceiptRecorded.userID = result.userID.rawValue
            response.readReceiptRecorded.readThroughRoomSequence = result.readThroughRoomSequence
            response.readReceiptRecorded.recordedAtMs = Int64(result.recordedAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleOpenDirectRoom(_ request: IMV2OpenDirectRoom, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let directMessaging else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        switch try await directMessaging.open(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID)) {
        case .opened(let room), .idempotent(let room):
            var response = IMV2Envelope(); response.directRoomOpened = .init()
            response.directRoomOpened.roomID = room.roomID.rawValue
            response.directRoomOpened.targetUserID = room.targetUserID.rawValue
            response.directRoomOpened.createdAtMs = Int64(room.createdAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleCreateGroupRoom(_ request: IMV2CreateGroupRoom, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupMessaging else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        // The one-frame command is deliberately capped below the transport
        // limit. New clients use the staged import, so no valid group depends
        // on a giant unbounded repeated field.
        guard request.initialMemberUserIds.count <= V2GroupAudienceImport.maximumMembersPerAppend else {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        let members = try request.initialMemberUserIds.map { try UserID($0) }
        // `delivery_mode` remains in the wire request for rolling-client
        // compatibility, but is deliberately not an authorization input.
        // The service derives the immutable room mode from the validated
        // initial audience, so a client cannot create a large standard-fanout
        // group (or select hybrid for a small group).
        switch try await groupMessaging.create(
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            title: request.title,
            initialMemberUserIDs: members
        ) {
        case .created(let room), .idempotent(let room):
            var response = IMV2Envelope(); response.groupRoomCreated = .init()
            response.groupRoomCreated.roomID = room.roomID.rawValue
            response.groupRoomCreated.title = room.title
            // A roster is never returned by room creation. It is read through
            // the authenticated, bounded ListRoomMembers directory.
            response.groupRoomCreated.memberUserIds = []
            response.groupRoomCreated.createdAtMs = Int64(room.createdAt.timeIntervalSince1970 * 1_000)
            response.groupRoomCreated.deliveryMode = switch room.deliveryMode {
            case .standardFanout: .standardFanout
            case .largeGroupHybrid: .largeGroupHybrid
            }
            response.groupRoomCreated.memberCount = UInt32(room.memberUserIDs.count)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .memberLimitReached: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleBeginGroupRoomCreation(_ request: IMV2BeginGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupAudienceImports else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let draft = try await groupAudienceImports.begin(actorUserID: identity.userID, operationID: try .init(request.operationID), title: request.title)
        var response = IMV2Envelope(); response.groupRoomCreationPrepared = .init()
        response.groupRoomCreationPrepared.operationID = draft.operationID.rawValue
        response.groupRoomCreationPrepared.title = draft.title
        response.groupRoomCreationPrepared.stagedMemberCount = UInt32(draft.stagedMemberCount)
        return response
    }

    private func handleAppendGroupRoomCreationMembers(_ request: IMV2AppendGroupRoomCreationMembers, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupAudienceImports else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let members = try request.memberUserIds.map { try UserID($0) }
        let draft = try await groupAudienceImports.append(actorUserID: identity.userID, operationID: try .init(request.operationID), memberUserIDs: members)
        var response = IMV2Envelope(); response.groupRoomCreationMembersAppended = .init()
        response.groupRoomCreationMembersAppended.operationID = draft.operationID.rawValue
        response.groupRoomCreationMembersAppended.stagedMemberCount = UInt32(draft.stagedMemberCount)
        return response
    }

    private func handleFinalizeGroupRoomCreation(_ request: IMV2FinalizeGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupAudienceImports else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let outcome = try await groupAudienceImports.finalize(actorUserID: identity.userID, operationID: try .init(request.operationID))
        switch outcome {
        case .created(let room), .idempotent(let room):
            return groupRoomCreatedEnvelope(room)
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .memberLimitReached: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleCancelGroupRoomCreation(_ request: IMV2CancelGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupAudienceImports else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let operationID = try GroupRoomOperationID(request.operationID)
        try await groupAudienceImports.cancel(actorUserID: identity.userID, operationID: operationID)
        var response = IMV2Envelope(); response.groupRoomCreationCancelled = .init()
        response.groupRoomCreationCancelled.operationID = operationID.rawValue
        return response
    }

    private func groupRoomCreatedEnvelope(_ room: V2GroupRoom) -> IMV2Envelope {
        var response = IMV2Envelope(); response.groupRoomCreated = .init()
        response.groupRoomCreated.roomID = room.roomID.rawValue
        response.groupRoomCreated.title = room.title
        response.groupRoomCreated.createdAtMs = Int64(room.createdAt.timeIntervalSince1970 * 1_000)
        response.groupRoomCreated.deliveryMode = room.deliveryMode == .standardFanout ? .standardFanout : .largeGroupHybrid
        response.groupRoomCreated.memberCount = UInt32(room.memberUserIDs.count)
        return response
    }

    private func handleListRoomMembers(_ request: IMV2ListRoomMembers, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let membershipDirectory else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let page = try await membershipDirectory.list(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            cursor: request.cursor.isEmpty ? nil : request.cursor,
            pageSize: Int(request.pageSize)
        ))
        var response = IMV2Envelope(); response.roomMembersPage = .init()
        response.roomMembersPage.roomID = page.roomID.rawValue
        response.roomMembersPage.membershipRevision = page.membershipRevision
        response.roomMembersPage.nextCursor = page.nextCursor ?? ""
        switch page.actorRole {
        case .owner: response.roomMembersPage.actorRole = .owner
        case .admin: response.roomMembersPage.actorRole = .admin
        case .member: response.roomMembersPage.actorRole = .member
        }
        response.roomMembersPage.members = page.entries.map { entry in
            var member = IMV2RoomMember()
            member.userID = entry.userID.rawValue
            switch entry.role {
            case .owner: member.role = .owner
            case .admin: member.role = .admin
            case .member: member.role = .member
            }
            if let publicIdentity = entry.publicIdentity {
                member.publicHandle = publicIdentity.handle.rawValue
                member.displayName = publicIdentity.displayName
            }
            return member
        }
        return response
    }

    private func handleGroupEventPull(_ request: IMV2GroupEventPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupEventLog else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let page = try await groupEventLog.pull(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            afterRoomSequence: request.afterRoomSequence,
            pageSize: Int(request.pageSize)
        )
        var response = IMV2Envelope()
        response.groupEventPage = .init()
        response.groupEventPage.roomID = page.roomID.rawValue
        response.groupEventPage.nextRoomSequence = page.nextRoomSequence
        response.groupEventPage.hasMore_p = page.hasMore
        response.groupEventPage.events = page.events.map {
            var event = IMV2GroupEvent()
            event.sourceEventID = $0.sourceEventID.rawValue
            event.roomSequence = $0.roomSequence
            event.projectionKind = $0.projectionKind
            event.payload = $0.payload
            return event
        }
        return response
    }

    private func handleGroupEventSubscribe(_ request: IMV2GroupEventSubscribe, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let groupEventLog else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let subscription = try await groupEventLog.subscribe(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID
        )
        var response = IMV2Envelope()
        response.groupEventSubscribed = .init()
        response.groupEventSubscribed.roomID = subscription.roomID.rawValue
        response.groupEventSubscribed.highWatermark = subscription.highWatermark
        return response
    }

    private func handleStrangerMessagePermission(_ request: IMV2SetStrangerMessagePermission, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let directMessaging else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let permission: V2StrangerMessagePermission
        switch request.permission {
        case .allow: permission = .allow
        case .deny: permission = .deny
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await directMessaging.setStrangerMessagePermission(actorUserID: identity.userID, operationID: try .init(request.operationID), permission: permission) {
        case .updated(let result, let updatedAt), .idempotent(let result, let updatedAt):
            var response = IMV2Envelope(); response.strangerMessagePermissionSet = .init()
            response.strangerMessagePermissionSet.permission = result == .allow ? .allow : .deny
            response.strangerMessagePermissionSet.updatedAtMs = Int64(updatedAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleUserAddPermission(_ request: IMV2SetUserAddPermission, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let directMessaging else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let permission: V2UserAddPermission
        switch request.permission {
        case .allow: permission = .allow
        case .deny: permission = .deny
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await directMessaging.setUserAddPermission(actorUserID: identity.userID, operationID: try .init(request.operationID), permission: permission) {
        case .updated(let result, let updatedAt), .idempotent(let result, let updatedAt):
            var response = IMV2Envelope(); response.userAddPermissionSet = .init()
            response.userAddPermissionSet.permission = result == .allow ? .allow : .deny
            response.userAddPermissionSet.updatedAtMs = Int64(updatedAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleRelationship(_ request: IMV2ChangeRelationship, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let socialRelationships else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let action: V2RelationshipAction
        switch request.action {
        case .request: action = .request
        case .accept: action = .accept
        case .reject: action = .reject
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await socialRelationships.changeRelationship(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID), action: action) {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.relationshipChanged = .init()
            response.relationshipChanged.targetUserID = change.targetUserID.rawValue
            response.relationshipChanged.action = switch change.action { case .request: .request; case .accept: .accept; case .reject: .reject; case .remove: .remove }
            response.relationshipChanged.resultingState = switch change.resultingState { case .none: .none; case .pending: .pending; case .accepted: .accepted }
            response.relationshipChanged.updatedAtMs = Int64(change.updatedAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .invalidState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .forbidden: return errorEnvelope(code: "FORBIDDEN", retryable: false)
        }
    }

    private func handleUserBlock(_ request: IMV2ChangeUserBlock, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let socialRelationships else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        let action: V2UserBlockAction
        switch request.action {
        case .block: action = .block
        case .unblock: action = .unblock
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await socialRelationships.changeUserBlock(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID), action: action) {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.userBlockChanged = .init()
            response.userBlockChanged.targetUserID = change.targetUserID.rawValue
            response.userBlockChanged.action = change.action == .block ? .block : .unblock
            response.userBlockChanged.isBlocked = change.isBlocked
            response.userBlockChanged.updatedAtMs = Int64(change.updatedAt.timeIntervalSince1970 * 1_000)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handlePull(_ request: IMV2SyncPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let token = request.syncToken.isEmpty ? nil : try V2SyncToken(request.syncToken)
        switch try await sync.pull(userID: identity.userID, deviceID: identity.deviceID, syncToken: token, requestedMaxRecords: Int(request.maxRecords)) {
        case .ready(let generation, let records, let nextToken, let receipt, let hasMore):
            var response = IMV2Envelope(); response.syncBatch = .init(); response.syncBatch.generation = generation
            response.syncBatch.records = records.map { record in var value = IMV2SyncRecord(); value.userSyncSequence = record.sequence; value.sourceEventID = record.sourceEventID.rawValue; value.projectionKind = record.projectionKind; value.payload = Data(record.payloadJSON.utf8); return value }
            response.syncBatch.nextSyncToken = nextToken.rawValue; response.syncBatch.syncReceipt = receipt.rawValue; response.syncBatch.hasMore_p = hasMore; response.syncBatch.capabilityProfile = identity.capabilityProfile
            return response
        case .resetRequired(let snapshotID, let generation, let base, let digest, let expiry):
            var response = IMV2Envelope(); response.resetRequired = .init(); response.resetRequired.snapshotID = snapshotID.rawValue; response.resetRequired.generation = generation; response.resetRequired.baseUserSyncSequence = base; response.resetRequired.manifestDigest = digest; response.resetRequired.expiresAtMs = Int64(expiry.timeIntervalSince1970 * 1_000)
            return response
        }
    }

    private func handleSnapshotManifest(_ request: IMV2SyncSnapshot, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let manifest = try await sync.fetchSnapshotManifest(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation)
        guard manifest.capabilityProfile == identity.capabilityProfile else {
            return errorEnvelope(code: "UPGRADE_REQUIRED", retryable: false)
        }
        var response = IMV2Envelope()
        response.snapshotManifest = .init()
        response.snapshotManifest.snapshotID = manifest.snapshotID.rawValue
        response.snapshotManifest.generation = manifest.generation
        response.snapshotManifest.baseUserSyncSequence = manifest.baseSequence
        response.snapshotManifest.manifestDigest = manifest.manifestDigest
        response.snapshotManifest.schemaVersion = manifest.schemaVersion
        response.snapshotManifest.capabilityProfile = manifest.capabilityProfile
        response.snapshotManifest.pageDigests = manifest.pageDigests
        response.snapshotManifest.nextSyncToken = manifest.nextSyncToken.rawValue
        response.snapshotManifest.syncReceipt = manifest.receipt.rawValue
        response.snapshotManifest.expiresAtMs = Int64(manifest.expiresAt.timeIntervalSince1970 * 1_000)
        return response
    }

    private func handleSnapshotPage(_ request: IMV2SnapshotPagePull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let page = try await sync.fetchSnapshotPage(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation, manifestDigest: request.manifestDigest, index: request.pageIndex)
        var response = IMV2Envelope()
        response.snapshotPage = .init()
        response.snapshotPage.snapshotID = page.snapshotID.rawValue
        response.snapshotPage.generation = page.generation
        response.snapshotPage.manifestDigest = page.manifestDigest
        response.snapshotPage.pageIndex = page.index
        response.snapshotPage.pageDigest = page.digest
        response.snapshotPage.payload = page.payload
        return response
    }

    private func successEnvelope() -> IMV2Envelope { var response = IMV2Envelope(); response.acknowledged = .init(); return response }
    private func errorEnvelope(code: String, retryable: Bool, retryAfter: Int = 0, currentRevision: UInt64 = 0) -> IMV2Envelope { var response = IMV2Envelope(); response.error = .init(); response.error.code = code; response.error.retryable = retryable; response.error.retryAfterSeconds = UInt32(max(retryAfter, 0)); response.error.currentRevision = currentRevision; return response }
}
