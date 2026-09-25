import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

// Runs only with the Store's borrowed transaction. The Store still opens the
// transaction, owns authorization receipt completion, and finalizes caches and
// command credits strictly after commit.
extension PostgresV2RoomWriteStore {
    func acceptInTransaction(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        importedForward: ForwardInboxAuthorization? = nil,
        fenceContext: V2ConfiguredRoomFenceContext? = nil,
        transaction: any Database
    ) async throws -> RoomWriteCommit {
            do {
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let clientMessageID = try scalarAcceptanceUUID(command.clientMessageID)
            try await acquireMessageOperationLock(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                sql: sql
            )
            let forwardSourceRoomID: UUID?
            if importedForward == nil, let expectedSource = forwardOwnerSourceRoomID {
                guard command.forwardedFrom != nil, let ownerRoutes else { throw V2RoomOwnerFenceError.ownerChanged }
                try await v2RequireForwardOwners(ownerRoutes, sql: sql)
                try await activationScope?.require([expectedSource, roomID], sql: sql)
                forwardSourceRoomID = expectedSource
            } else if importedForward == nil, let forwarded = command.forwardedFrom {
                forwardSourceRoomID = try await v2LockForwardRooms(
                    sourceMessageID: scalarAcceptanceUUID(forwarded.messageID), targetRoomID: roomID, sql: sql
                )
            } else {
                forwardSourceRoomID = nil
            }
            if forwardOwnerSourceRoomID == nil || authorizationGrants != nil {
                if let fenceContext, let activationScope,
                   command.forwardedFrom == nil, importedForward == nil,
                   forwardOwnerSourceRoomID == nil, authorizationGrants == nil {
                    try await fenceContext.requireSelectedOwnersAndActivations(
                        roomIDs: [roomID], expectedRoutes: ownerRoutes,
                        expectedKinds: controlScopeRoomKinds, scope: activationScope)
                } else {
                    try await requireSelectedOwners([roomID], sql: sql)
                }
            }
            let loadedContext = try await ScalarMessagePreflight.load(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                now: now,
                cachedDirectPolicy: cachedDirectPolicy,
                sql: sql
            )
            let room = loadedContext.room
            guard controlScopeRoomKinds == nil || controlScopeRoomKinds?[roomID] == room.kind else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Every accepted public message uses the room log. Historical
            // deployment selectors must never restore per-user fanout writes.
            let usesDirectRoomLog = room.kind == "direct"

            // An accepted inbox is still live work until its terminal marker.
            // Fence it before message replay can resume post-commit effects.
            if let importedForward { try await v2AssertForwardInboxOwner(importedForward, sql: sql) }

            // A completed command must replay its canonical result even if a
            // later membership change removes the sender. Otherwise a lost
            // acceptance response becomes an observable false rejection and
            // clients cannot safely retain their immutable operation ID.
            switch try loadedContext.existingOperation() {
            case .accepted(let receipt, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(receipt.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .idempotent(receipt) : .idempotencyConflict
                )
            case .denied(let priorDenial, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(priorDenial.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .denied(priorDenial) : .idempotencyConflict
                )
            case nil:
                break
            }
            guard room.capacityProfileID == capacityProfile.id else {
                throw V2RoomWriteStoreError.capacityProfileMismatch
            }
            guard room.frozenAt == nil else {
                throw V2RoomWriteStoreError.roomFrozen
            }
            let admissionSnapshot = try loadedContext.admissionSnapshot()
            let admission = admissionSnapshot.room
            let shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await v2AuthorizeContentWrite(
                roomID: roomID, isGroup: room.kind == "group", frozenAt: room.frozenAt,
                actorIsActive: try senderIsActive(admissionSnapshot.senderIsActive, roomID: roomID, senderID: senderID),
                actorRole: admissionSnapshot.actorRole,
                isMuted: admissionSnapshot.muted != false, sql: sql
            )
            let directContext: DirectMessageAcceptanceContext?
            if room.kind == "direct" {
                let context = try directMessageContext(from: loadedContext.directPolicySnapshot(), roomID: roomID, senderID: senderID)
                directContext = context
                if let restriction = context.restriction {
                    let denied = try await persistDirectMessageDenied(
                        fingerprint: command.fingerprint,
                        roomID: command.roomID,
                        roomUUID: roomID,
                        senderID: senderID,
                        clientMessageID: clientMessageID,
                        sourceEventID: try scalarAcceptanceUUID(identifiers.eventID),
                        nextTimelineSequence: try roomWriteNextSequence(room.timelineSequence),
                        createdAt: now,
                        reason: restriction,
                        currentCanSend: context.senderCanSend,
                        sql: sql
                    )
                    return .init(outcome: .denied(denied))
                }
            } else {
                directContext = nil
            }
            try await assertMentionsAuthorized(command.mentions, roomID: roomID, membershipRevision: room.membershipRevision, senderID: senderID, sql: sql)
            let mediaPresentations = try await RoomWriteMediaAcceptance.presentations(
                command: command,
                importedForward: importedForward,
                forwardSourceRoomID: forwardSourceRoomID,
                senderID: senderID,
                now: now,
                sql: sql
            )
            try await assertReplyTarget(command.replyTo, roomID: roomID, actorID: senderID, sql: sql)
            let roomState = try room.commandState(roomID: command.roomID, admission: admission)
            let shardState = try shard.admissionState()
            // The complete path owns a foreground PostgreSQL transaction and
            // may already hold room, membership and policy locks. Never call
            // the process credit actor here: a refill borrows from the same
            // bounded pool and can deadlock when every foreground connection
            // is waiting for that nested acquisition. Warm plain sends reserve
            // credits before their transaction in the conditional fast path;
            // this cold/rich path uses the exact conditional SQL reservation
            // below as its final statement instead.
            let shardStateForReduction = shardState
            let result: V2SendMessageAcceptanceResult
            // 房间日志是权威副本：不预留任何逐用户投递成本，被 @ 的成员只收到通知。
            result = try roomLogReduction(
                command: command,
                roomState: roomState,
                shardState: shardStateForReduction,
                profile: capacityProfile.limits,
                identifiers: identifiers,
                now: now
            )
            guard case .accepted(let writeSet) = result else {
                return .init(
                    outcome: result.outcome(
                        mediaPresentations: mediaPresentations,
                        groupCapacityClass: room.kind == "group" ? room.capacityClass : nil
                    )
                )
            }
            // Do this only after the generic admission reducer accepts. A
            // capacity rejection returns normally from this transaction, so
            // consuming the stranger window earlier would be a silent quota
            // loss despite no accepted message.
            if let directContext, directContext.requiresStrangerQuota {
                try await consumeDirectMessageQuota(
                    senderID: senderID,
                    recipientID: directContext.recipientID,
                    policy: strangerMessagePolicy,
                    now: now,
                    sql: sql
                )
            }
            let loadedDirectPolicyCacheEntry = loadedContext.directPolicyCacheEntry()
            var updatedDirectPolicyCacheEntry = loadedDirectPolicyCacheEntry
            // The reply marker is monotonic. Once a sender has an accepted
            // message we no longer issue a no-op UPDATE for every later send.
            // The actual value comes from the transaction snapshot, never
            // from the process-local cache.
            var replyMarkerAdvanced = false
            if let directContext, !directContext.senderHasReplied {
                replyMarkerAdvanced = try await markDirectSenderHasReplied(
                    roomID: roomID,
                    senderID: senderID,
                    sql: sql
                )
                if replyMarkerAdvanced {
                    updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?.markingSenderHasReplied()
                }
            }

            let timelineWriteSet = try withTimelineSequence(writeSet, timelineSequence: roomWriteNextSequence(room.timelineSequence))
            let acceptedMessage = timelineWriteSet.acceptedMessage.materialized(
                mediaPresentations: mediaPresentations,
                groupCapacityClass: room.kind == "group" ? room.capacityClass : nil,

                sourceEventID: timelineWriteSet.eventID,
                acceptedMembershipRevision: try scalarAcceptanceUnsigned(room.membershipRevision),
                directRecipientUserID: directContext.map { .init(uuid: $0.recipientID) },
                projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(timelineWriteSet.acceptedMessage.createdAt)
            )
            let acceptedState = try V2MessageProjectionState(
                accepted: acceptedMessage,
                forwardedFromMessageID: command.forwardedFrom?.messageID,
                forwardedFromUserID: command.forwardedFrom?.senderUserID
            )
            let messageStateEventID = try scalarAcceptanceUUID(timelineWriteSet.eventID)
            let storedMessageState = try V2StoredMessageProjectionState(
                state: acceptedState,
                originEventID: messageStateEventID,
                stateEventID: messageStateEventID,
                createdAt: acceptedMessage.createdAt
            )
            let shardReservation = try shardAdmissionReservation(
                from: shardStateForReduction,
                to: timelineWriteSet.nextShardState
            )
            try await persist(
                timelineWriteSet,
                command: command,
                mediaPresentations: mediaPresentations,
                messageProjectionState: storedMessageState,
                room: room,
                sql: sql
            )
            if let directContext,
               (!directContext.senderProfileVisibleToRecipient || directContext.senderCanSend != true || directContext.supportAccountID != nil) {
                let recipientID = directContext.recipientID
                let projectionChanges = try await appendDirectPostAcceptanceProjections(
                    roomID: roomID,
                    senderID: senderID,
                    recipientID: recipientID,
                    senderProfileVisibleToRecipient: directContext.senderProfileVisibleToRecipient,
                    senderCanSend: directContext.senderCanSend,
                    sourceEventID: messageStateEventID,
                    createdAt: timelineWriteSet.acceptedMessage.createdAt,
                    stateVersion: timelineWriteSet.acceptedMessage.timelineSequence,
                    sql: sql
                )
                updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?
                    .applyingPostAcceptanceProjection(
                        senderCapabilityInserted: projectionChanges.senderCapabilityInserted,
                        recipientProfileInserted: projectionChanges.recipientProfileInserted
                    )
                if let supportAccountID = directContext.supportAccountID {
                    try await openSupportSessionIfNeeded(
                        roomID: roomID,
                        senderID: senderID,
                        supportAccountID: supportAccountID,
                        createdAt: timelineWriteSet.acceptedMessage.createdAt,
                        sql: sql
                    )
                }
            }
            // Keep the contended shard counter update as the final, narrow
            // statement. Folding this lock into the large data-modifying CTE
            // made the complete write graph wait behind one of nine shared
            // shard rows and multiplied foreground connection occupancy.
            // A rejection still throws inside this transaction, so all prior
            // message and room-event writes roll back atomically.
            try await reserveShardAdmission(
                shardReservation,
                room: room,
                retryAfterSeconds: capacityProfile.limits.retryAfterSeconds,
                now: now,
                sql: sql
            )
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if usesDirectRoomLog,
               Self.isPlainDirectRoomLogBatchShape(.init(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now
               )),
               let cacheEntry = updatedDirectPolicyCacheEntry,
               fastPlainDirectPolicyIsCacheCandidate(cacheEntry) {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: room.roomShardID,
                    capacityProfileID: room.capacityProfileID,
                    membershipRevision: room.membershipRevision,
                    shardState: try shard.admissionState()
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            let reciprocalReplyCacheUpdate: DirectReplyCacheUpdate?
            if replyMarkerAdvanced,
               let directContext,
               let loadedDirectPolicyCacheEntry {
                reciprocalReplyCacheUpdate = .init(
                    key: .init(
                        roomID: roomID,
                        senderID: directContext.recipientID
                    ),
                    expectedDirectPairRevision: loadedDirectPolicyCacheEntry.directPairRevision
                )
            } else {
                reciprocalReplyCacheUpdate = nil
            }
            return .init(
                outcome: .accepted(acceptedMessage),
                directPolicyCacheUpdate: updatedDirectPolicyCacheEntry,
                directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                shardAdmissionCommandCredit: nil,
                roomAdmissionHeatObservation: usesDirectRoomLog
                    && roomAdmissionCommandCreditPool != nil
                    && directContext?.supportAccountID == nil
                    && command.media.isEmpty
                    && command.mentions.isEmpty
                    && command.replyTo == nil
                    && command.forwardedFrom == nil
                    ? roomID : nil
            )
            } catch {
                throw error
            }
    }
}

private func scalarAcceptanceUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func scalarAcceptanceUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
