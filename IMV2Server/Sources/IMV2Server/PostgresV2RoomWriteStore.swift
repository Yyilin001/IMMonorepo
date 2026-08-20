import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL implementation of the V2 acceptance boundary.
///
/// Room-local state is serialized by `rooms -> room_admission`. Shard
/// admission is evaluated optimistically, then reserved with one conditional
/// atomic increment as the final statement in the transaction. This preserves
/// exact capacity and lease fencing without holding the shared shard row while
/// policy checks and durable message writes run.
public struct PostgresV2RoomWriteStore: V2RoomWriteStore {
    private let database: any Database
    private let strangerMessagePolicy: V2StrangerMessagePolicy
    private let shadowForwarder: any V2UserShardProjectionShadowing
    private let contentReviewMode: V2ContentReviewMode
    private let directFanoutMode: V2DirectFanoutMode
    private let directRoomLogAdmissionMode: V2DirectRoomLogAdmissionMode
    private let payloadWriteMode: V2FanoutPayloadWriteMode
    private let directSendPolicyCache: V2DirectSendPolicyCache
    private let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?

    public init(
        database: any Database,
        strangerMessagePolicy: V2StrangerMessagePolicy,
        shadowForwarder: any V2UserShardProjectionShadowing,
        contentReviewMode: V2ContentReviewMode,
        directFanoutMode: V2DirectFanoutMode = .planner,
        directRoomLogAdmissionMode: V2DirectRoomLogAdmissionMode = .room,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body,
        directSendPolicyCache: V2DirectSendPolicyCache = .init(),
        shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool? = nil
    ) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
        self.shadowForwarder = shadowForwarder
        self.contentReviewMode = contentReviewMode
        self.directFanoutMode = directFanoutMode
        self.directRoomLogAdmissionMode = directRoomLogAdmissionMode
        self.payloadWriteMode = payloadWriteMode
        self.directSendPolicyCache = directSendPolicyCache
        self.shardAdmissionCommandCreditPool = shardAdmissionCommandCreditPool
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        let roomID = try uuid(command.roomID)
        let senderID = try uuid(command.senderUserID)
        let cacheKey = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: senderID)
        let cachedDirectPolicy = await directSendPolicyCache.value(for: cacheKey)
        let commit: RoomWriteCommit
        do {
            commit = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            var shardCreditToken: V2ShardAdmissionCommandCreditPool.Token?
            do {
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let clientMessageID = try uuid(command.clientMessageID)
            try await acquireMessageOperationLock(
                senderID: senderID,
                clientMessageID: clientMessageID,
                sql: sql
            )
            let loadedContext = try await loadMessageAcceptanceContext(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                now: now,
                cachedDirectPolicy: cachedDirectPolicy,
                sql: sql
            )
            let room = loadedContext.room
            guard room.capacityProfileID == capacityProfile.id else {
                throw V2RoomWriteStoreError.capacityProfileMismatch
            }
            // A direct room has a fixed, authorization-checked audience. In
            // room-log mode its canonical event is the durable delivery
            // record; per-user Delivery/Inbox rows would only duplicate that
            // fact. This is deployment policy, not client input.
            let usesDirectRoomLog = room.kind == "direct" && directFanoutMode == .roomLog
            let usesDirectRoomLogShardAdmission = usesDirectRoomLog
                && directRoomLogAdmissionMode == .shardOnly

            // A completed command must replay its canonical result even if a
            // later membership change removes the sender. Otherwise a lost
            // acceptance response becomes an observable false rejection and
            // clients cannot safely retain their immutable operation ID.
            switch try loadedContext.existingOperation() {
            case .accepted(let existing):
                let priorMedia = try await sql.raw("""
                    SELECT reference.media_id, media.content_type, media.byte_count
                    FROM im_v2.message_media_references AS reference
                    INNER JOIN im_v2.media_objects AS media ON media.media_id = reference.media_id
                    WHERE reference.message_id = \(bind: existing.messageID)
                    ORDER BY reference.ordinal
                    """).all(decoding: MessageMediaPresentationRow.self)
                let priorMentions = try await sql.raw("SELECT mention_kind, mentioned_user_id FROM im_v2.message_mentions WHERE message_id = \(bind: existing.messageID) ORDER BY ordinal").all(decoding: MentionRow.self)
                let accepted = try existing.acceptedMessage(
                    media: try priorMedia.map { try .init(mediaID: .init($0.mediaID.uuidString)) },
                    mediaPresentations: try priorMedia.map { try $0.presentation },
                    mentions: try priorMentions.map { try $0.target },
                    groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                    usesRoomEventLog: usesDirectRoomLog
                )
                let outcome: V2SendMessageOutcome = accepted.roomID == command.roomID && accepted.text == command.text && accepted.media == command.media && accepted.mentions == command.mentions
                    && accepted.entities == command.entities && accepted.replyTo == command.replyTo
                    ? .idempotent(accepted)
                    : .idempotencyConflict
                // A retry may be recovering a crash after the source
                // transaction committed but before cross-shard shadowing.
                // Preserve the lookup-based recovery path only for this rare
                // replay; new acceptances carry their exact projection delta.
                return .init(outcome: outcome, acceptedDirectProjectionShadows: nil)
            case .denied(let priorDenial):
                return .init(
                    outcome: priorDenial.roomID == command.roomID
                        ? .denied(priorDenial)
                        : .idempotencyConflict,
                    acceptedDirectProjectionShadows: []
                )
            case nil:
                break
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
            guard admissionSnapshot.senderIsActive == true,
                  let role = admissionSnapshot.actorRole,
                  let actorRole = V2RoomMembershipRole(rawValue: role)
            else {
                throw V2RoomWriteStoreError.actorNotEligible
            }
            if room.kind == "group" {
                let configuredPermissions = try await v2ResolvedGroupPermissions(roomID: roomID, role: actorRole, sql: sql)
                guard V2GroupPermissionDefaults.allows(role: actorRole, permission: .sendMessages, configured: configuredPermissions) else {
                    throw V2RoomWriteStoreError.actorNotEligible
                }
            }
            guard admissionSnapshot.muted == false else {
                throw V2RoomWriteStoreError.actorMuted
            }
            let directContext: DirectMessageAcceptanceContext?
            if room.kind == "direct" {
                let context = try directMessageContext(from: loadedContext.directPolicySnapshot())
                directContext = context
                if let restriction = context.restriction {
                    let denied = try await persistDirectMessageDenied(
                        roomID: command.roomID,
                        roomUUID: roomID,
                        senderID: senderID,
                        clientMessageID: clientMessageID,
                        sourceEventID: try uuid(identifiers.eventID),
                        nextTimelineSequence: try unsigned(room.timelineSequence + 1),
                        createdAt: now,
                        reason: restriction,
                        currentCanSend: context.senderCanSend,
                        sql: sql
                    )
                    return .init(outcome: .denied(denied), acceptedDirectProjectionShadows: [])
                }
            } else {
                directContext = nil
            }
            try await assertMentionsAuthorized(command.mentions, roomID: roomID, membershipRevision: room.membershipRevision, senderID: senderID, sql: sql)
            let mediaOwnerID: UUID
            if let forwarded = command.forwardedFrom {
                guard let sourceMessageID = UUID(uuidString: forwarded.messageID.rawValue), let sourceSenderID = UUID(uuidString: forwarded.senderUserID.rawValue),
                      // Lock the source message, but not its room.  The
                      // destination room is already locked above; locking a
                      // second room here creates an A→B / B→A cycle when two
                      // users forward in opposite directions.  A withdrawal
                      // serializes on this message row, so the attribution
                      // remains valid at commit without broadening the lock.
                      let source = try await sql.raw("SELECT message.room_id, message.sender_user_id, message.text_body, message.withdrawn_at, room.membership_revision FROM im_v2.messages AS message INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id WHERE message.message_id = \(bind: sourceMessageID) FOR UPDATE OF message").first(decoding: ForwardSourceRow.self),
                      source.senderUserID == sourceSenderID, source.withdrawnAt == nil, source.text == command.text
                else { throw V2RoomWriteStoreError.actorNotEligible }
                let canReadSource = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: source.roomID) AND user_id = \(bind: senderID) AND joined_revision <= \(bind: source.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: source.membershipRevision))) AS value").first(decoding: ForwardVisibilityRow.self)?.value ?? false
                guard canReadSource else { throw V2RoomWriteStoreError.actorNotEligible }
                // A forward may only reuse an attachment from the exact
                // source message; attribution is not a general media grant.
                let sourceMedia = try await sql.raw("SELECT media_id FROM im_v2.message_media_references WHERE message_id = \(bind: sourceMessageID) ORDER BY ordinal").all(decoding: ForwardMediaRow.self).map(\.mediaID)
                guard sourceMedia == (try command.media.map { try uuid($0.mediaID) }) else { throw V2RoomWriteStoreError.actorNotEligible }
                mediaOwnerID = sourceSenderID
            } else { mediaOwnerID = senderID }
            let mediaPresentations = try await assertAvailableMedia(command.media, ownerID: mediaOwnerID, now: now, sql: sql)
            try await assertReplyTarget(command.replyTo, roomID: roomID, sql: sql)
            // Hybrid delivery never expands @everyone. Explicit user mentions
            // are bounded by the command limit and receive a finite reliable
            // projection; everyone else observes the canonical room event.
            let hybridReliableTargets = room.deliveryMode == .largeGroupHybrid
                ? hybridMentionTargetIDs(command.mentions, excluding: senderID)
                : []
            let roomState = try room.commandState(roomID: command.roomID, admission: admission)
            let shardState = try shard.admissionState()
            let shardStateForReduction: ShardAdmissionState
            if usesDirectRoomLog, let shardAdmissionCommandCreditPool {
                switch try await shardAdmissionCommandCreditPool.acquire(
                    roomShardID: room.roomShardID,
                    capacityProfileID: room.capacityProfileID,
                    shardState: shardState,
                    now: now
                ) {
                case .granted(let token, let effectiveShardState):
                    shardCreditToken = token
                    shardStateForReduction = effectiveShardState
                case .rateLimited:
                    return .init(
                        outcome: .rateLimited(retryAfterSeconds: capacityProfile.limits.retryAfterSeconds),
                        acceptedDirectProjectionShadows: []
                    )
                case .unavailable(let reason):
                    return .init(outcome: .unavailable(reason), acceptedDirectProjectionShadows: [])
                }
            } else {
                shardStateForReduction = shardState
            }
            let result: V2SendMessageAcceptanceResult
            if usesDirectRoomLog {
                result = if usesDirectRoomLogShardAdmission {
                    try directRoomLogShardOnlyReduction(
                        command: command,
                        roomState: roomState,
                        shardState: shardStateForReduction,
                        profile: capacityProfile.limits,
                        identifiers: identifiers,
                        now: now
                    )
                } else {
                    try roomLogReduction(
                        command: command,
                        roomState: roomState,
                        shardState: shardStateForReduction,
                        profile: capacityProfile.limits,
                        identifiers: identifiers,
                        reliableTargetCount: 0,
                        now: now
                    )
                }
            } else {
                switch room.deliveryMode {
                case .standardFanout:
                result = try V2SendMessageReducer.reduce(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    now: now
                )
                case .largeGroupHybrid:
                result = try hybridReduction(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    reliableTargetCount: hybridReliableTargets.count,
                    now: now
                )
                }
            }
            guard case .accepted(let writeSet) = result else {
                if let token = shardCreditToken, let shardAdmissionCommandCreditPool {
                    await shardAdmissionCommandCreditPool.release(token, now: now)
                    shardCreditToken = nil
                }
                return .init(
                    outcome: result.outcome(
                        mediaPresentations: mediaPresentations,
                        groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                        usesRoomEventLog: usesDirectRoomLog
                    ),
                    acceptedDirectProjectionShadows: []
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
            }

            let timelineWriteSet = try withTimelineSequence(writeSet, timelineSequence: unsigned(room.timelineSequence + 1))
            let acceptedMessage = timelineWriteSet.acceptedMessage.materialized(
                mediaPresentations: mediaPresentations,
                groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                usesRoomEventLog: usesDirectRoomLog
            )
            let acceptedState = try V2MessageProjectionState(
                accepted: acceptedMessage,
                forwardedFromMessageID: command.forwardedFrom?.messageID,
                forwardedFromUserID: command.forwardedFrom?.senderUserID
            )
            let messageStateEventID = try uuid(timelineWriteSet.eventID)
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
                directRecipientID: directContext?.recipientID,
                sql: sql
            )
            var acceptedDirectProjectionShadows: [DirectProjectionShadowRequest] = []
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
                    sql: sql
                )
                if projectionChanges.recipientProfileInserted {
                    acceptedDirectProjectionShadows.append(.init(
                        userID: try .init(recipientID.uuidString),
                        sourceEventID: timelineWriteSet.eventID,
                        projectionKinds: ["direct_room_profile"]
                    ))
                }
                if projectionChanges.senderCapabilityInserted {
                    acceptedDirectProjectionShadows.append(.init(
                        userID: command.senderUserID,
                        sourceEventID: timelineWriteSet.eventID,
                        projectionKinds: ["direct_sending_capability"]
                    ))
                }
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
            // message/fan-out writes roll back atomically.
            if shardCreditToken != nil {
                guard shardReservation.commandDelta == 1,
                      shardReservation.fanoutDelta == 0,
                      shardReservation.outstandingUnitDelta == 0,
                      shardReservation.outstandingPlanDelta == 0
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            } else {
                try await reserveShardAdmission(
                    shardReservation,
                    room: room,
                    retryAfterSeconds: capacityProfile.limits.retryAfterSeconds,
                    now: now,
                    sql: sql
                )
            }
            return .init(
                outcome: .accepted(acceptedMessage),
                acceptedDirectProjectionShadows: acceptedDirectProjectionShadows,
                directPolicyCacheUpdate: replyMarkerAdvanced
                    ? loadedContext.directPolicyCacheEntry()?.markingSenderHasReplied()
                    : loadedContext.directPolicyCacheEntry(),
                shardAdmissionCommandCredit: shardCreditToken
            )
            } catch {
                if let shardCreditToken, let shardAdmissionCommandCreditPool {
                    await shardAdmissionCommandCreditPool.release(shardCreditToken, now: now)
                }
                throw error
            }
            }
        } catch let rejection as LateShardAdmissionRejection {
            switch rejection {
            case .rateLimited(let retryAfterSeconds):
                commit = .init(
                    outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds),
                    acceptedDirectProjectionShadows: []
                )
            case .unavailable(let reason):
                commit = .init(outcome: .unavailable(reason), acceptedDirectProjectionShadows: [])
            }
        }
        if let entry = commit.directPolicyCacheUpdate {
            await directSendPolicyCache.insert(entry, for: cacheKey)
        }
        if let shardCreditToken = commit.shardAdmissionCommandCredit,
           let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardCreditToken)
        }
        try await shadowCommittedDirectProjectionsIfNeeded(command: command, commit: commit)
        return commit.outcome
    }

    /// Applies the reducer's shard delta against the current row instead of
    /// overwriting counters derived from an earlier snapshot. Concurrent rooms
    /// can therefore perform all expensive work in parallel and serialize only
    /// for this single tail update. Predicates mirror the schema constraints so
    /// a capacity race becomes a normal admission rejection, never a partial
    /// commit or a constraint error.
    private func shardAdmissionReservation(
        from initial: ShardAdmissionState,
        to next: ShardAdmissionState
    ) throws -> ShardAdmissionReservation {
        guard let initialLease = initial.lease, let nextLease = next.lease,
              initialLease.id == nextLease.id,
              initialLease.generation == nextLease.generation
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let commandDelta = nextLease.commandWindow.used - initialLease.commandWindow.used
        let fanoutDelta = nextLease.fanoutWindow.used - initialLease.fanoutWindow.used
        let outstandingUnitDelta = next.outstandingFanoutUnits - initial.outstandingFanoutUnits
        let outstandingPlanDelta = next.outstandingPlans - initial.outstandingPlans
        guard commandDelta >= 0, fanoutDelta >= 0,
              outstandingUnitDelta >= 0, outstandingPlanDelta >= 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        return try .init(
            leaseID: uuid(nextLease.id),
            generation: signed(nextLease.generation),
            commandDelta: commandDelta,
            fanoutDelta: fanoutDelta,
            outstandingUnitDelta: outstandingUnitDelta,
            outstandingPlanDelta: outstandingPlanDelta
        )
    }

    private func reserveShardAdmission(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        let applied = try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = command_window_used + \(bind: reservation.commandDelta),
                fanout_window_used = fanout_window_used + \(bind: reservation.fanoutDelta),
                outstanding_fanout_units = outstanding_fanout_units + \(bind: reservation.outstandingUnitDelta),
                outstanding_plans = outstanding_plans + \(bind: reservation.outstandingPlanDelta)
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: reservation.leaseID)
              AND generation = \(bind: reservation.generation)
              AND valid_until > \(bind: now)
              AND command_window_used <= command_window_limit - \(bind: reservation.commandDelta)
              AND fanout_window_used <= fanout_window_limit - \(bind: reservation.fanoutDelta)
              AND outstanding_fanout_units <= max_outstanding_fanout_units - \(bind: reservation.outstandingUnitDelta)
              AND outstanding_plans <= max_outstanding_plans - \(bind: reservation.outstandingPlanDelta)
            RETURNING 1 AS applied
            """).first(decoding: ShardAdmissionMutationRow.self)
        guard applied != nil else {
            try await throwShardAdmissionRejection(
                reservation,
                room: room,
                retryAfterSeconds: retryAfterSeconds,
                now: now,
                sql: sql
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// Classifies the zero-row result of the conditional reservation without
    /// weakening the authoritative predicate. This second read exists only on
    /// a rejected transaction; a successful reservation needs no extra read.
    private func throwShardAdmissionRejection(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        guard let current = try await sql.raw("""
            SELECT lease_id, generation, valid_until
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
            """).first(decoding: CurrentShardLeaseRow.self)
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.leaseID == reservation.leaseID,
              current.generation == reservation.generation
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.validUntil > now else {
            throw LateShardAdmissionRejection.unavailable(.expiredShardLease)
        }
        throw LateShardAdmissionRejection.rateLimited(retryAfterSeconds: retryAfterSeconds)
    }

    /// The control store remains the source of truth for direct-profile
    /// visibility. Once a first direct message commits, mirror that profile
    /// to the recipient's live user shard just as the direct-open path does.
    /// Running this after the transaction is deliberate: a retry of the same
    /// immutable client message repeats the idempotent shadow if a process
    /// crashed after commit but before forwarding.
    private func shadowCommittedDirectProjectionsIfNeeded(
        command: V2SendMessageCommand,
        commit: RoomWriteCommit
    ) async throws {
        let message: V2AcceptedMessage
        switch commit.outcome {
        case .accepted(let value):
            // The normal hot path knows exactly which source projections were
            // inserted. Established conversations usually insert none, so
            // they no longer pay route, migration and projection lookups after
            // every committed message.
            if let shadows = commit.acceptedDirectProjectionShadows {
                for shadow in shadows {
                    _ = try await shadowForwarder.shadowIfForwarding(
                        userID: shadow.userID,
                        sourceEventID: shadow.sourceEventID,
                        projectionKinds: shadow.projectionKinds
                    )
                }
                return
            }
            message = value
        case .idempotent(let value):
            message = value
        case .denied(let denied):
            _ = try await shadowForwarder.shadowIfForwarding(userID: command.senderUserID, sourceEventID: denied.sourceEventID, projectionKinds: ["timeline_activity", "direct_sending_capability"])
            return
        case .idempotencyConflict, .rateLimited, .unavailable:
            return
        }
        // A group acceptance carries its immutable delivery mode. Avoid an
        // unnecessary direct-pair lookup on the high-volume group path.
        guard message.groupDeliveryMode == nil else { return }
        guard let sql = database as? any SQLDatabase,
              let roomID = UUID(uuidString: message.roomID.rawValue),
              let senderID = UUID(uuidString: message.senderUserID.rawValue),
              let pair = try await sql.raw("SELECT lower_user_id, higher_user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: roomID)").first(decoding: DirectRoomPairRow.self),
              let event = try await sql.raw("SELECT event_id FROM im_v2.room_events WHERE room_id = \(bind: roomID) AND room_sequence = \(bind: try signed(message.roomSequence)) AND event_type = 'message.accepted'").first(decoding: DirectMessageEventRow.self)
        else { return }
        let recipientID: UUID
        if pair.lowerUserID == senderID { recipientID = pair.higherUserID }
        else if pair.higherUserID == senderID { recipientID = pair.lowerUserID }
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        _ = try await shadowForwarder.shadowIfForwarding(
            userID: try .init(recipientID.uuidString),
            sourceEventID: try .init(event.eventID.uuidString),
            projectionKinds: ["direct_room_profile"]
        )
        _ = try await shadowForwarder.shadowIfForwarding(
            userID: command.senderUserID,
            sourceEventID: try .init(event.eventID.uuidString),
            projectionKinds: ["direct_sending_capability"]
        )
    }

    /// Acquires the operation fence in its own statement. PostgreSQL fixes a
    /// statement snapshot before evaluating a CTE; after a concurrent sender
    /// releases this lock, the following read must therefore start with a new
    /// snapshot to observe the committed idempotency result.
    private func acquireMessageOperationLock(
        senderID: UUID,
        clientMessageID: UUID,
        sql: any SQLDatabase
    ) async throws {
        let key = "v2-message-operation:" + senderID.uuidString + ":" + clientMessageID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    /// One transaction-scoped read loads the room, idempotency result, room
    /// admission, sender membership, and direct-message policy together. The
    /// operation fence has already established a fresh snapshot; the CTE lock
    /// graph preserves room -> room admission -> sender membership -> direct
    /// pair. The shared shard row remains a narrow final reservation.
    private func loadMessageAcceptanceContext(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        now: Date,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        sql: any SQLDatabase
    ) async throws -> MessageAcceptanceContextRow {
        // A cached sender reply marker is only a performance hint. The
        // durable direct-pair and policy-version rows remain locked until the
        // message transaction commits, so a block or preference change either
        // precedes this decision (revision mismatch -> database evaluation)
        // or follows this accepted message. `senderHasReplied` is monotonic;
        // a cache hit lets steady-state sends use compatible shared locks
        // instead of the exclusive locks needed by a first reply-marker write.
        let directPairLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF pair"
            : "FOR UPDATE OF pair"
        let directPolicyVersionLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF sender_version, recipient_version"
            : "FOR KEY SHARE OF sender_version, recipient_version"
        let rows = try await sql.raw("""
            WITH locked_room AS MATERIALIZED (
                SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.delivery_mode, room.frozen_at,
                       room.room_id
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT 'accepted'::text AS prior_outcome_kind,
                       message.message_id AS prior_message_id,
                       message.room_id AS prior_room_id,
                       message.room_sequence AS prior_room_sequence,
                       message.timeline_sequence AS prior_timeline_sequence,
                       message.sender_user_id AS prior_sender_user_id,
                       message.client_message_id AS prior_client_message_id,
                       message.text_body AS prior_text_body,
                       message.rich_entities::text AS prior_rich_entities,
                       message.reply_to_message_id AS prior_reply_to_message_id,
                       message.created_at AS prior_created_at,
                       NULL::uuid AS prior_source_event_id,
                       NULL::text AS prior_denial_reason
                FROM locked_room
                JOIN im_v2.messages AS message ON TRUE
                WHERE message.sender_user_id = \(bind: senderID)
                  AND message.client_message_id = \(bind: clientMessageID)
                UNION ALL
                SELECT 'denied'::text, NULL::uuid, denial.room_id, NULL::bigint,
                       denial.timeline_sequence, denial.sender_user_id,
                       denial.client_message_id, NULL::text, NULL::text,
                       NULL::uuid, denial.created_at, denial.source_event_id,
                       denial.reason
                FROM locked_room
                JOIN im_v2.direct_message_denials AS denial ON TRUE
                WHERE denial.sender_user_id = \(bind: senderID)
                  AND denial.client_message_id = \(bind: clientMessageID)
            ), prior_operation_count AS MATERIALIZED (
                SELECT COUNT(*)::integer AS prior_operation_count FROM prior_operation
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (SELECT 1 FROM prior_operation)
            ), locked_admission AS MATERIALIZED (
                SELECT admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.fanout_window_limit AS room_fanout_window_limit,
                       admission.fanout_window_used AS room_fanout_window_used,
                       admission.max_outstanding_fanout_units AS room_max_outstanding_fanout_units,
                       admission.outstanding_fanout_units AS room_outstanding_fanout_units,
                       admission.max_outstanding_plans AS room_max_outstanding_plans,
                       admission.outstanding_plans AS room_outstanding_plans,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used,
                       shard.fanout_window_limit AS shard_fanout_window_limit,
                       shard.fanout_window_used AS shard_fanout_window_used,
                       shard.max_outstanding_fanout_units AS shard_max_outstanding_fanout_units,
                       shard.outstanding_fanout_units AS shard_outstanding_fanout_units,
                       shard.max_outstanding_plans AS shard_max_outstanding_plans,
                       shard.outstanding_plans AS shard_outstanding_plans
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = \(bind: senderID)
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = \(bind: senderID)
                             AND mute.mute_until > \(bind: now)
                       ) AS muted
                FROM fresh_room AS room
                CROSS JOIN locked_admission
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = \(bind: senderID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT pair.room_id, pair.lower_user_id, pair.higher_user_id,
                       pair.lower_profile_visible_to_higher,
                       pair.higher_profile_visible_to_lower,
                       pair.lower_can_send, pair.higher_can_send,
                       pair.lower_has_replied, pair.higher_has_replied,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id
                FROM fresh_room AS room
                CROSS JOIN locked_actor
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = \(bind: senderID)
                       OR pair.higher_user_id = \(bind: senderID))
                \(unsafeRaw: directPairLockClause)
            ), direct_policy_versions AS MATERIALIZED (
                SELECT pair.*, sender_version.revision AS sender_policy_revision,
                       recipient_version.revision AS recipient_policy_revision
                FROM direct_pair AS pair
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = \(bind: senderID)
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = pair.recipient_user_id
                \(unsafeRaw: directPolicyVersionLockClause)
            ), special AS MATERIALIZED (
                SELECT account.account_user_id, account.account_kind, account.status,
                       account.allows_customer_messages, account.allows_service_messages
                FROM im_v2.special_accounts AS account
                JOIN direct_policy_versions AS pair
                  ON account.account_user_id = \(bind: senderID)
                  OR account.account_user_id = pair.recipient_user_id
                ORDER BY account.account_user_id
                FOR KEY SHARE OF account
            ), direct_policy AS MATERIALIZED (
                SELECT pair.recipient_user_id, pair.direct_policy_revision,
                       pair.sender_policy_revision, pair.recipient_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_can_send
                            ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_has_replied
                            ELSE pair.higher_has_replied
                       END AS sender_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.recipientIsActive)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = pair.recipient_user_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) END AS recipient_is_active,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.blocked)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_blocks AS block
                           WHERE (block.blocker_user_id = pair.lower_user_id AND block.blocked_user_id = pair.higher_user_id)
                              OR (block.blocker_user_id = pair.higher_user_id AND block.blocked_user_id = pair.lower_user_id)
                       ) END AS blocked,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.isFriend)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_relationships AS relationship
                           WHERE relationship.lower_user_id = pair.lower_user_id
                             AND relationship.higher_user_id = pair.higher_user_id
                             AND relationship.state = 'accepted'
                       ) END AS is_friend,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_has_replied
                            ELSE pair.lower_has_replied
                       END AS recipient_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.allowsStrangers)
                            ELSE COALESCE((
                           SELECT preference.allows_stranger_messages
                           FROM im_v2.user_stranger_message_preferences AS preference
                           WHERE preference.user_id = pair.recipient_user_id
                       ), TRUE) END AS allows_strangers,
                       (SELECT account_kind FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_kind,
                       (SELECT status FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_status,
                       (SELECT allows_service_messages FROM special WHERE account_user_id = \(bind: senderID)) AS sender_allows_service_messages,
                       (SELECT account_kind FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                       (SELECT status FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_status,
                       (SELECT allows_customer_messages FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                FROM direct_policy_versions AS pair
            )
            SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.delivery_mode, room.frozen_at,
                   count.prior_operation_count,
                   prior.prior_outcome_kind, prior.prior_message_id,
                   prior.prior_room_id, prior.prior_room_sequence,
                   prior.prior_timeline_sequence, prior.prior_sender_user_id,
                   prior.prior_client_message_id, prior.prior_text_body,
                   prior.prior_rich_entities, prior.prior_reply_to_message_id,
                   prior.prior_created_at, prior.prior_source_event_id,
                   prior.prior_denial_reason,
                   admission.*, actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id, policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision, policy.sender_policy_revision,
                   policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active, policy.blocked,
                   policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages, policy.recipient_account_kind,
                   policy.recipient_account_status, policy.recipient_allows_customer_messages
            FROM locked_room AS room
            CROSS JOIN prior_operation_count AS count
            LEFT JOIN prior_operation AS prior ON TRUE
            LEFT JOIN locked_admission AS admission ON TRUE
            LEFT JOIN locked_actor AS actor ON TRUE
            LEFT JOIN direct_policy AS policy ON TRUE
            """).all(decoding: MessageAcceptanceContextRow.self)
        guard rows.count == 1, let row = rows.first else {
            throw rows.isEmpty ? V2RoomWriteStoreError.roomNotFound : V2RoomWriteStoreError.corruptPersistenceState
        }
        guard row.priorOperationCount <= 1 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return row
    }

    /// The SQL loader above owns the consistent database snapshot and locks;
    /// this pure mapping deliberately retains the existing direct-policy
    /// decision table unchanged.
    private func directMessageContext(
        from policy: DirectMessagePolicySnapshotRow
    ) throws -> DirectMessageAcceptanceContext {

        let recipientID = policy.recipientUserID
        let restriction: V2DirectMessageDenied.Reason?
        if policy.senderAccountKind != nil {
            restriction = policy.senderAccountStatus == "active" && policy.senderAllowsServiceMessages == true ? nil : .generic
            // Special subjects have no public gateway credential. A call that
            // reaches this branch originated at the trusted service boundary.
        } else if let recipientAccountKind = policy.recipientAccountKind {
            if policy.recipientAccountStatus != "active" {
                restriction = .generic
            } else if recipientAccountKind == "system" {
                restriction = .systemAccountReadOnly
            } else {
                restriction = policy.recipientAllowsCustomerMessages == true ? nil : .generic
            }
        } else if !policy.recipientIsActive || policy.blocked {
            restriction = .generic
        } else if policy.isFriend || policy.recipientHasReplied {
            restriction = nil
        } else {
            restriction = policy.allowsStrangers ? nil : .generic
        }
        return .init(
            recipientID: recipientID,
            restriction: restriction,
            requiresStrangerQuota: policy.senderAccountKind == nil && policy.recipientAccountKind == nil && !policy.isFriend && !policy.recipientHasReplied,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderHasReplied: policy.senderHasReplied,
            supportAccountID: policy.recipientAccountKind == "customer_support" && policy.recipientAccountStatus == "active"
                ? recipientID
                : nil
        )
    }

    /// Capacity is consumed only after the generic admission reducer accepts,
    /// preserving the existing no-quota-loss invariant for a rejected send.
    private func consumeDirectMessageQuota(senderID: UUID, recipientID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
        let windowStart = now.addingTimeInterval(-policy.window)
        let consumed = try await sql.raw("""
            INSERT INTO im_v2.stranger_message_windows (sender_user_id, recipient_user_id, window_started_at, message_count)
            VALUES (\(bind: senderID), \(bind: recipientID), \(bind: now), 1)
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN EXCLUDED.window_started_at ELSE im_v2.stranger_message_windows.window_started_at END,
                message_count = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN 1 ELSE im_v2.stranger_message_windows.message_count + 1 END
            WHERE im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart)
               OR im_v2.stranger_message_windows.message_count < \(bind: policy.maximumMessagesPerWindow)
            RETURNING message_count
            """).first(decoding: DirectMessageWindowRow.self)
        guard consumed != nil else { throw V2RoomWriteStoreError.strangerMessageLimitReached }
    }

    /// The stranger-message policy only needs to know whether the peer has
    /// ever replied. Keeping that monotonic fact on the already-locked direct
    /// pair removes a per-send `messages` existence scan without changing the
    /// point at which a reply becomes visible: this update commits atomically
    /// with the accepted message.
    @discardableResult
    private func markDirectSenderHasReplied(
        roomID: UUID,
        senderID: UUID,
        sql: any SQLDatabase
    ) async throws -> Bool {
        let updated = try await sql.raw("""
            UPDATE im_v2.direct_room_pairs AS pair
            SET lower_has_replied = CASE
                    WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.lower_has_replied
                END,
                higher_has_replied = CASE
                    WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.higher_has_replied
                END,
                direct_policy_revision = pair.direct_policy_revision + 1
            WHERE pair.room_id = \(bind: roomID)
              AND (pair.lower_user_id = \(bind: senderID)
                   OR pair.higher_user_id = \(bind: senderID))
              AND ((pair.lower_user_id = \(bind: senderID) AND NOT pair.lower_has_replied)
                   OR (pair.higher_user_id = \(bind: senderID) AND NOT pair.higher_has_replied))
            RETURNING pair.room_id
            """).first(decoding: DirectReplyMarkerMutationRow.self)
        return updated != nil
    }

    /// A rejection is a private fact for the sender, not a message and not a
    /// room event. The operation table makes a transport retry idempotent and
    /// prevents duplicate activity rows for one client message ID.
    private func persistDirectMessageDenied(
        roomID: RoomID,
        roomUUID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sourceEventID: UUID,
        nextTimelineSequence: UInt64,
        createdAt: Date,
        reason: V2DirectMessageDenied.Reason,
        currentCanSend: Bool?,
        sql: any SQLDatabase
    ) async throws -> V2DirectMessageDenied {
        let timelineSequence = try signed(nextTimelineSequence)
        let activityType = directMessageTimelineActivityType(for: reason)
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        // The denial row references its private timeline activity. Insert the
        // referenced fact first; both rows still commit atomically inside the
        // surrounding message transaction.
        try await sql.raw("INSERT INTO im_v2.room_timeline_activities (source_event_id, room_id, timeline_sequence, activity_type, recipient_user_id, created_at) VALUES (\(bind: sourceEventID), \(bind: roomUUID), \(bind: timelineSequence), \(bind: activityType), \(bind: senderID), \(bind: createdAt))").run()
        try await sql.raw("INSERT INTO im_v2.direct_message_denials (sender_user_id, client_message_id, room_id, source_event_id, timeline_sequence, created_at, reason) VALUES (\(bind: senderID), \(bind: clientMessageID), \(bind: roomUUID), \(bind: sourceEventID), \(bind: timelineSequence), \(bind: createdAt), \(bind: reason.rawValue))").run()
        let activityPayload = try JSONSerialization.data(withJSONObject: ["event_type": activityType, "room_id": roomUUID.uuidString, "timeline_sequence": timelineSequence, "server_created_at_ms": Int64(createdAt.timeIntervalSince1970 * 1_000)])
        try await appendPrivateSyncRecord(userID: senderID, sourceEventID: sourceEventID, projectionKind: "timeline_activity", payload: activityPayload, createdAt: createdAt, sql: sql)
        try await appendDirectSendingCapabilityIfChanged(
            roomID: roomUUID,
            recipientID: senderID,
            sourceEventID: sourceEventID,
            canSend: false,
            currentCanSend: currentCanSend,
            createdAt: createdAt,
            sql: sql
        )
        return try .init(roomID: roomID, sourceEventID: .init(sourceEventID.uuidString), timelineSequence: nextTimelineSequence, createdAt: createdAt, reason: reason)
    }

    /// The public denial reason deliberately hides whether a block, stranger
    /// preference, or inactive special account caused the rejection. The
    /// private timeline still uses the stable projection vocabulary consumed
    /// by SQLite and constrained by PostgreSQL.
    private func directMessageTimelineActivityType(for reason: V2DirectMessageDenied.Reason) -> String {
        switch reason {
        case .generic:
            "direct_message_restricted"
        case .systemAccountReadOnly:
            "system_account_read_only"
        }
    }

    private func appendDirectSendingCapabilityIfChanged(
        roomID: UUID,
        recipientID: UUID,
        sourceEventID: UUID,
        canSend: Bool,
        currentCanSend: Bool?,
        createdAt: Date,
        sql: any SQLDatabase
    ) async throws {
        guard currentCanSend != canSend else { return }
        guard let mutation = try await sql.raw("""
            WITH sequence AS (
                INSERT INTO im_v2.user_sync_sequences AS current (user_id, next_sequence)
                VALUES (\(bind: recipientID), 1)
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = current.next_sequence + 1
                RETURNING next_sequence
            ), log_insert AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT \(bind: recipientID), sequence.next_sequence, \(bind: sourceEventID),
                       'direct_sending_capability',
                       jsonb_build_object('room_id', \(bind: roomID.uuidString),
                                          'can_send', \(bind: canSend),
                                          'updated_at_ms', \(bind: Int64(createdAt.timeIntervalSince1970 * 1_000))),
                       \(bind: createdAt)
                FROM sequence
                RETURNING user_id
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND EXISTS (SELECT 1 FROM log_insert)
                RETURNING pair.room_id
            )
            SELECT (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectCapabilityMutationRow.self),
              mutation.insertedCount == 1,
              mutation.pairCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// The customer's first accepted message creates the service session in
    /// the same transaction as the message. Retried messages reuse the room
    /// row, while a closed session is deliberately not reopened by a stale
    /// duplicate operation.
    private func openSupportSessionIfNeeded(roomID: UUID, senderID: UUID, supportAccountID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.support_conversation_sessions (room_id, support_account_user_id, customer_user_id, state, opened_at, last_activity_at, closed_at) VALUES (\(bind: roomID), \(bind: supportAccountID), \(bind: senderID), 'open', \(bind: createdAt), \(bind: createdAt), NULL) ON CONFLICT (room_id) DO UPDATE SET last_activity_at = EXCLUDED.last_activity_at, state = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN 'open' ELSE im_v2.support_conversation_sessions.state END, closed_at = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN NULL ELSE im_v2.support_conversation_sessions.closed_at END").run()
    }

    private func appendPrivateSyncRecord(userID: UUID, sourceEventID: UUID, projectionKind: String, payload: Data, createdAt: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: DirectMessageSyncSequenceRow.self) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard let payloadJSON = String(data: payload, encoding: .utf8) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence.nextSequence), \(bind: sourceEventID), \(bind: projectionKind), \(bind: payloadJSON)::jsonb, \(bind: createdAt))").run()
    }

    private func withTimelineSequence(_ writeSet: V2MessageAcceptanceTransaction, timelineSequence: UInt64) throws -> V2MessageAcceptanceTransaction {
        let message = writeSet.acceptedMessage
        let revisedMessage = V2AcceptedMessageDraft(messageID: message.messageID, roomID: message.roomID, roomSequence: message.roomSequence, timelineSequence: timelineSequence, senderUserID: message.senderUserID, clientMessageID: message.clientMessageID, text: message.text, media: message.media, mentions: message.mentions, entities: message.entities, replyTo: message.replyTo, groupDeliveryMode: message.groupDeliveryMode, createdAt: message.createdAt)
        return .init(acceptedMessage: revisedMessage, eventID: writeSet.eventID, fanoutPlan: writeSet.fanoutPlan, nextRoomState: writeSet.nextRoomState, nextShardState: writeSet.nextShardState)
    }

    /// Makes an unopened direct pair visible to the recipient only after its
    /// first message has passed block, stranger-preference and quota checks in
    /// this same transaction. The profile precedes the asynchronous message
    /// fan-out in that recipient's sync stream, so a delivered first message
    /// always has a stable conversation identity.
    /// Pair-local producer markers are locked by `directMessageContext` and
    /// therefore remain an exact, compaction-independent answer to whether a
    /// projection changed. Established conversations return without another
    /// PostgreSQL round trip; a state transition allocates its sequences and
    /// advances the markers atomically with the message transaction.
    private func appendDirectPostAcceptanceProjections(
        roomID: UUID,
        senderID: UUID,
        recipientID: UUID,
        senderProfileVisibleToRecipient: Bool,
        senderCanSend: Bool?,
        sourceEventID: UUID,
        createdAt: Date,
        sql: any SQLDatabase
    ) async throws -> DirectPostAcceptanceProjectionChanges {
        guard !senderProfileVisibleToRecipient || senderCanSend != true else {
            return .init(senderCapabilityInserted: false, recipientProfileInserted: false)
        }
        guard let mutation = try await sql.raw("""
            WITH profile AS MATERIALIZED (
                SELECT public_handle, display_name, account_kind, revision, updated_at
                FROM im_v2.public_user_profiles
                WHERE user_id = \(bind: senderID)
                  AND state = 'active'
                  AND revision > 0
            ), needed AS MATERIALIZED (
                SELECT \(bind: senderID)::uuid AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'can_send', TRUE,
                           'updated_at_ms', \(bind: Int64(createdAt.timeIntervalSince1970 * 1_000))
                       ) AS payload
                WHERE \(bind: senderCanSend != true)
                UNION ALL
                SELECT \(bind: recipientID), 'direct_room_profile',
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'target_user_id', \(bind: senderID.uuidString),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms', (extract(epoch FROM profile.updated_at) * 1000)::bigint
                       )
                FROM profile
                WHERE \(bind: !senderProfileVisibleToRecipient)
            ), sequence_insert AS (
                INSERT INTO im_v2.user_sync_sequences AS current (user_id, next_sequence)
                SELECT user_id, 1
                FROM needed
                ORDER BY user_id
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = current.next_sequence + 1
                RETURNING user_id, next_sequence
            ), log_insert AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT needed.user_id, sequence_insert.next_sequence, \(bind: sourceEventID),
                       needed.projection_kind, needed.payload,
                       \(bind: createdAt)
                FROM needed
                JOIN sequence_insert USING (user_id)
                RETURNING user_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM needed)
                RETURNING pair.room_id
            )
            SELECT EXISTS (SELECT 1 FROM profile) AS profile_exists,
                   (SELECT count(*) FROM needed) AS needed_count,
                   (SELECT count(*) FROM log_insert WHERE projection_kind = 'direct_room_profile') AS profile_inserted_count,
                   (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectRoomProfileMutationRow.self),
              mutation.profileExists,
              mutation.insertedCount == mutation.neededCount,
              mutation.pairCount == 1,
              (0...2).contains(mutation.neededCount),
              (0...1).contains(mutation.profileInsertedCount),
              mutation.profileInsertedCount <= mutation.insertedCount,
              (0...1).contains(mutation.insertedCount - mutation.profileInsertedCount)
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(
            senderCapabilityInserted: mutation.insertedCount - mutation.profileInsertedCount == 1,
            recipientProfileInserted: mutation.profileInsertedCount == 1
        )
    }

    private func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        mediaPresentations: [V2MediaPresentation],
        messageProjectionState: V2StoredMessageProjectionState,
        room: RoomRow,
        directRecipientID: UUID?,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let roomID = try uuid(message.roomID)
        let messageID = try uuid(message.messageID)
        let eventID = try uuid(writeSet.eventID)
        let planID = try uuid(writeSet.fanoutPlan.id)
        let senderID = try uuid(message.senderUserID)
        let clientMessageID = try uuid(message.clientMessageID)
        let roomSequence = try signed(message.roomSequence)
        let timelineSequence = try signed(message.timelineSequence)
        let roomAdmission = writeSet.nextRoomState.admission
        guard let shardLease = writeSet.nextShardState.lease else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let shardLeaseID = try uuid(shardLease.id)
        let shardLeaseGeneration = try signed(shardLease.generation)

        guard let mediaJSON = String(data: try JSONEncoder().encode(message.media.map { $0.mediaID.rawValue }), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let entitiesJSON = String(data: try JSONEncoder().encode(message.entities), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let replyToMessageID = message.replyTo?.messageID.rawValue ?? ""
        let forwardedFromMessageID = try command.forwardedFrom.map { try uuid($0.messageID) }
        let forwardedFromUserID = try command.forwardedFrom.map { try uuid($0.senderUserID) }
        let mediaPresentationWire: [[String: Any]] = mediaPresentations.map { presentation in
            [
                "media_id": presentation.mediaID.rawValue,
                "kind": presentation.kind.rawValue,
                "content_type": presentation.contentType,
                "byte_count": presentation.byteCount,
            ]
        }
        guard let mediaPresentationsJSON = String(data: try JSONSerialization.data(withJSONObject: mediaPresentationWire), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let mentionedUserIDs = message.mentions.compactMap { target -> String? in
            guard case .user(let userID) = target else { return nil }
            return userID.rawValue
        }
        guard let mentionedUsersJSON = String(data: try JSONEncoder().encode(mentionedUserIDs), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let references = try message.media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let referencesJSON = try roomWriteJSON(references)
        let mentions = try message.mentions.enumerated().map { ordinal, target in
            switch target {
            case .user(let userID):
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "user",
                    mentionedUserID: try uuid(userID)
                )
            case .everyone:
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "everyone",
                    mentionedUserID: nil
                )
            }
        }
        let mentionsJSON = try roomWriteJSON(mentions)

        let usesDirectRoomLog = room.kind == "direct" && directFanoutMode == .roomLog
        if usesDirectRoomLog {
            guard writeSet.fanoutPlan.reservation.cost.targetCount == 0 else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await persistRoomLogMessage(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                shardLeaseID: shardLeaseID,
                shardLeaseGeneration: shardLeaseGeneration,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: directRoomLogAdmissionMode == .room,
                sql: sql
            )
            return
        }

        if room.deliveryMode == .standardFanout {
            try await persistStandardFanout(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                planID: planID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                shardLeaseID: shardLeaseID,
                shardLeaseGeneration: shardLeaseGeneration,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                messageProjectionState: messageProjectionState,
                directRecipientID: directRecipientID,
                sql: sql
            )
            return
        }

        try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence), timeline_sequence = \(bind: timelineSequence)
            WHERE room_id = \(bind: roomID)
            """).run()
        let hybridReliableTargets = hybridMentionTargetIDs(message.mentions, excluding: senderID)
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET command_window_used = \(bind: roomAdmission.commandWindow.used),
                fanout_window_used = \(bind: roomAdmission.fanoutWindow.used),
                outstanding_fanout_units = \(bind: roomAdmission.outstandingFanoutUnits),
                outstanding_plans = \(bind: roomAdmission.outstandingPlans),
                shard_lease_id = \(bind: shardLeaseID),
                shard_lease_generation = \(bind: shardLeaseGeneration)
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, rich_entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: entitiesJSON)::jsonb, NULLIF(\(bind: replyToMessageID), '')::uuid, \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID), \(bind: message.createdAt))
            """).run()
        if contentReviewMode.enqueuesJobs {
            // This outbox row commits with the message. A process crash between
            // acceptance and worker wake therefore cannot create an unreviewed
            // blind spot; leases recover the work without touching the hot send
            // path again.
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                VALUES (\(bind: messageID), \(bind: roomID), 1, 'pending', \(bind: message.createdAt))
                """).run()
        }
        if !message.media.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT \(bind: messageID), reference.media_id, reference.ordinal, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                """).run()
        }
        if !message.mentions.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT \(bind: messageID), mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                """).run()
        }
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES
                (\(bind: eventID), \(bind: roomID), \(bind: roomSequence), 'message.accepted', \(bind: senderID),
                 jsonb_build_object(
                    'event_type', 'message.accepted',
                    'message_id', \(bind: messageID.uuidString),
                    'room_id', \(bind: roomID.uuidString),
                    'room_sequence', \(bind: roomSequence),
                    'timeline_sequence', \(bind: timelineSequence),
                    'sender_user_id', \(bind: senderID.uuidString),
                    'text', \(bind: message.text),
                    'media_ids', \(bind: mediaJSON)::jsonb,
                    'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                    'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                    'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                    'entities', \(bind: entitiesJSON)::jsonb,
                    'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                    'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                    'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                    'message_revision', 1,
                    'server_created_at_ms', \(bind: Int64(message.createdAt.timeIntervalSince1970 * 1_000)
                 )),
                 \(bind: room.membershipRevision), \(bind: message.createdAt))
            """).run()
        switch room.deliveryMode {
        case .standardFanout:
            preconditionFailure("standard fan-out returns through the set-based persistence path")
        case .largeGroupHybrid:
            guard writeSet.fanoutPlan.reservation.cost.targetCount == hybridReliableTargets.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if hybridReliableTargets.isEmpty {
                // Retain a terminal plan row so every operation result has
                // the same audit shape, while making global fan-out
                // structurally impossible for an ordinary large-group event.
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plans
                        (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                         target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at, terminal_at)
                    VALUES
                        (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: room.membershipRevision),
                         '{"kind":"hybrid_room_log"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                         0, 0, 'terminal', \(bind: message.createdAt), \(bind: message.createdAt))
                    """).run()
            } else {
                let targetsJSON = String(data: try JSONSerialization.data(withJSONObject: hybridReliableTargets.map(\.uuidString)), encoding: .utf8)!
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plans
                        (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                         target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                    VALUES
                        (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: room.membershipRevision),
                         '{"kind":"hybrid_mention_targets"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                         \(bind: hybridReliableTargets.count), \(bind: hybridReliableTargets.count), 'planning', \(bind: message.createdAt))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: eventID), value::uuid
                    FROM jsonb_array_elements_text(\(bind: targetsJSON)::jsonb) AS value
                    """).run()
                try await sql.raw("INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at) VALUES (\(bind: eventID), \(bind: planID), 'pending', \(bind: message.createdAt))").run()
            }
        }
        try await PostgresV2MessageProjectionStateRepository().persist(
            messageProjectionState,
            storage: .roomEvent,
            sql: sql
        )
    }

    /// The ordinary direct/group send path used to issue one network round
    /// trip per durable row. PostgreSQL already gives a data-modifying CTE one
    /// statement-level transaction boundary, so chain every dependent write
    /// through `RETURNING` and validate the exact mutation cardinality once.
    private func persistStandardFanout(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        planID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        shardLeaseID: UUID,
        shardLeaseGeneration: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        messageProjectionState: V2StoredMessageProjectionState,
        directRecipientID: UUID?,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        let targetCount = writeSet.fanoutPlan.reservation.cost.targetCount
        let targetRule = targetRuleJSON(writeSet.fanoutPlan.reservation.cost, commandRule: command.targetRule)
        let usesDirectPreplannedFanout = directFanoutMode == .preplanned && directRecipientID != nil
        if usesDirectPreplannedFanout && targetCount != 2 {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: admission.commandWindow.used),
                    fanout_window_used = \(bind: admission.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: admission.outstandingFanoutUnits),
                    outstanding_plans = \(bind: admission.outstandingPlans),
                    shard_lease_id = \(bind: shardLeaseID),
                    shard_lease_generation = \(bind: shardLeaseGeneration)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                RETURNING admission.room_id
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_update.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_update
                RETURNING message_id, room_id
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: Int64(message.createdAt.timeIntervalSince1970 * 1_000))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id, room_id, payload
            ), message_state_insert AS (
                INSERT INTO im_v2.message_projection_states
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at, payload_storage)
                SELECT \(bind: messageProjectionState.stateID),
                       \(bind: messageProjectionState.messageID),
                       event_insert.room_id,
                       \(bind: messageProjectionState.messageRevision),
                       \(bind: messageProjectionState.variantKey),
                       event_insert.event_id,
                       \(bind: messageProjectionState.stateEventID),
                       \(bind: messageProjectionState.isWithdrawn),
                       \(bind: messageProjectionState.payloadSchemaVersion),
                       NULL,
                       \(bind: messageProjectionState.createdAt),
                       'room_event'
                FROM event_insert
                WHERE event_insert.payload = \(bind: messageProjectionState.payloadJSON)::jsonb
                ON CONFLICT DO NOTHING
                RETURNING state_id
            ), message_state_existing AS MATERIALIZED (
                SELECT state_id
                FROM im_v2.message_projection_state_values
                WHERE state_id = \(bind: messageProjectionState.stateID)
                  AND message_id = \(bind: messageProjectionState.messageID)
                  AND room_id = \(bind: messageProjectionState.roomID)
                  AND message_revision = \(bind: messageProjectionState.messageRevision)
                  AND variant_key = \(bind: messageProjectionState.variantKey)
                  AND origin_event_id = \(bind: messageProjectionState.originEventID)
                  AND state_event_id IS NOT DISTINCT FROM \(bind: messageProjectionState.stateEventID)
                  AND is_withdrawn = \(bind: messageProjectionState.isWithdrawn)
                  AND payload_schema_version = \(bind: messageProjectionState.payloadSchemaVersion)
                  AND payload = \(bind: messageProjectionState.payloadJSON)::jsonb
            ), message_state_ready AS MATERIALIZED (
                SELECT state_id FROM message_state_insert
                UNION ALL
                SELECT state_id FROM message_state_existing
            ), shared_payload_insert AS (
                INSERT INTO im_v2.fanout_sync_payloads
                    (source_event_id, projection_kind, payload,
                     message_state_id, created_at)
                SELECT event_insert.event_id, 'message',
                       CASE WHEN \(bind: payloadWriteMode == .reference)
                            THEN NULL ELSE event_insert.payload END,
                       message_state_ready.state_id, \(bind: message.createdAt)
                FROM event_insert
                CROSS JOIN message_state_ready
                ON CONFLICT DO NOTHING
                RETURNING source_event_id
            ), authoritative_direct_targets AS MATERIALIZED (
                SELECT membership.user_id
                FROM event_insert
                JOIN im_v2.direct_room_pairs AS pair
                  ON pair.room_id = event_insert.room_id
                 AND (
                     (pair.lower_user_id = \(bind: senderID)
                      AND pair.higher_user_id = \(bind: directRecipientID))
                     OR
                     (pair.higher_user_id = \(bind: senderID)
                      AND pair.lower_user_id = \(bind: directRecipientID))
                 )
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = pair.room_id
                 AND membership.user_id IN (pair.lower_user_id, pair.higher_user_id)
                 AND membership.joined_revision <= \(bind: room.membershipRevision)
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > \(bind: room.membershipRevision))
                WHERE \(bind: usesDirectPreplannedFanout)
            ), direct_routed_targets AS MATERIALIZED (
                SELECT target.user_id,
                       COALESCE(route_override.write_bucket, config.default_write_bucket)
                           AS target_shard_bucket,
                       COALESCE(route_override.router_epoch, config.router_epoch)
                           AS observed_router_epoch
                FROM authoritative_direct_targets AS target
                CROSS JOIN im_v2.user_shard_router_configuration AS config
                LEFT JOIN im_v2.user_shard_route_overrides AS route_override
                  ON route_override.user_id = target.user_id
                WHERE config.configuration_key = TRUE
            ), direct_shape AS MATERIALIZED (
                SELECT COUNT(target.user_id)::bigint AS target_count,
                       COUNT(route.user_id)::bigint AS routed_count,
                       MIN(target.user_id::text)::uuid AS first_user_id,
                       MAX(target.user_id::text)::uuid AS last_user_id
                FROM authoritative_direct_targets AS target
                LEFT JOIN direct_routed_targets AS route USING (user_id)
            ), plan_insert AS (
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence,
                     committed_membership_revision, target_rule, enumeration_checkpoint,
                     target_count, reserved_fanout_cost, state, created_at,
                     enumerated_target_count)
                SELECT \(bind: planID), event_insert.event_id, event_insert.room_id,
                       \(bind: roomSequence), \(bind: room.membershipRevision),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN \(bind: targetRule)::jsonb ||
                                 jsonb_build_object('planning_strategy', 'direct_preplanned')
                            ELSE \(bind: targetRule)::jsonb
                       END,
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN jsonb_build_object('after_user_id', direct_shape.last_user_id::text)
                            ELSE jsonb_build_object('after_user_id', NULL)
                       END,
                       \(bind: targetCount), \(bind: targetCount),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN 'planned' ELSE 'planning'
                       END,
                       \(bind: message.createdAt),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN \(bind: targetCount) ELSE 0
                       END
                FROM event_insert
                CROSS JOIN direct_shape
                RETURNING plan_id, source_event_id, state
            ), direct_completion_insert AS (
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary,
                     target_count, state)
                SELECT plan.source_event_id, plan.plan_id,
                       jsonb_build_object(
                           'first_user_id', direct_shape.first_user_id::text,
                           'last_user_id', direct_shape.last_user_id::text,
                           'membership_revision', \(bind: room.membershipRevision),
                           'audience_kind', 'direct_preplanned'
                       ),
                       direct_shape.target_count, 'pending'
                FROM plan_insert AS plan
                CROSS JOIN direct_shape
                WHERE plan.state = 'planned'
                RETURNING source_event_id, completion_unit_id
            ), direct_delivery_insert AS (
                INSERT INTO im_v2.fanout_deliveries
                    (source_event_id, target_user_id, projection_kind,
                     completion_unit_id, target_shard_bucket, observed_router_epoch,
                     fresh_direct_eligible)
                SELECT completion.source_event_id, route.user_id, 'message',
                       completion.completion_unit_id, route.target_shard_bucket,
                       route.observed_router_epoch, TRUE
                FROM direct_completion_insert AS completion
                CROSS JOIN direct_routed_targets AS route
                RETURNING source_event_id, target_user_id
            ), outbox_insert AS (
                INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at)
                SELECT source_event_id, plan_id, 'pending', \(bind: message.createdAt)
                FROM plan_insert
                WHERE state = 'planning'
                RETURNING source_event_id
            )
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_update) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count,
                   ((SELECT count(*) FROM message_state_insert)
                    + (SELECT count(*) FROM message_state_existing)) AS message_state_count,
                   (SELECT count(*) FROM shared_payload_insert) AS shared_payload_count,
                   (SELECT count(*) FROM plan_insert) AS plan_count,
                   (SELECT count(*) FROM outbox_insert) AS outbox_count,
                   (SELECT target_count FROM direct_shape) AS direct_target_count,
                   (SELECT routed_count FROM direct_shape) AS direct_routed_count,
                   (SELECT count(*) FROM direct_completion_insert) AS completion_count,
                   (SELECT count(*) FROM direct_delivery_insert) AS delivery_count,
                   (SELECT count(*) FROM plan_insert WHERE state = 'planned') AS preplanned_plan_count
            """).first(decoding: SetBasedRoomWriteMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1,
              mutation.messageStateCount == 1,
              mutation.sharedPayloadCount == 1,
              mutation.planCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        if usesDirectPreplannedFanout {
            guard mutation.directTargetCount == 2 else {
                // The target set is derived only from the locked immutable
                // pair and revision-fenced memberships. Never let a corrupt
                // direct audience silently degrade into a different target.
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if mutation.directRoutedCount == 2 {
                guard mutation.preplannedPlanCount == 1,
                      mutation.completionCount == 1,
                      mutation.deliveryCount == 2,
                      mutation.outboxCount == 0
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            } else {
                // A missing route configuration preserves the established
                // durable planner recovery path. The mutually exclusive CTEs
                // guarantee that this branch has no partial direct work.
                guard mutation.preplannedPlanCount == 0,
                      mutation.completionCount == 0,
                      mutation.deliveryCount == 0,
                      mutation.outboxCount == 1
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            }
        } else {
            guard mutation.preplannedPlanCount == 0,
                  mutation.completionCount == 0,
                  mutation.deliveryCount == 0,
                  mutation.outboxCount == 1
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
        }
    }

    /// Persists the canonical direct-room event without manufacturing a
    /// second durable copy for each of its two members. The event and its
    /// revision-fenced membership checks are the recovery contract; the
    /// foreground wake is intentionally outside this transaction and is only
    /// a latency optimisation.
    private func persistRoomLogMessage(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        shardLeaseID: UUID,
        shardLeaseGeneration: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        // The load test's dominant shape is a plain direct message. Keep the
        // rich path below intact for review/media/mentions, but do not make a
        // plain message pay for three empty data-modifying CTEs or rewrite
        // room-admission fields that cannot change in direct room-log mode.
        if !contentReviewMode.enqueuesJobs,
           message.media.isEmpty,
           message.mentions.isEmpty {
            try await persistPlainRoomLogMessage(
                message: message,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: admission.commandWindow.used,
                entitiesJSON: entitiesJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: persistsRoomAdmission,
                sql: sql
            )
            return
        }
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: admission.commandWindow.used),
                    fanout_window_used = \(bind: admission.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: admission.outstandingFanoutUnits),
                    outstanding_plans = \(bind: admission.outstandingPlans),
                    shard_lease_id = \(bind: shardLeaseID),
                    shard_lease_generation = \(bind: shardLeaseGeneration)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                  AND \(bind: persistsRoomAdmission)
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_id FROM room_update
                WHERE NOT \(bind: persistsRoomAdmission)
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_gate.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_gate
                RETURNING message_id, room_id
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: Int64(message.createdAt.timeIntervalSince1970 * 1_000))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id
            )
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// The narrow direct room-log commit for a plain message. This remains a
    /// single statement so the room sequence, admission debit, message and
    /// recovery event cannot become externally visible independently. The
    /// immutable event stores a content reference; its pull path reads the
    /// matching version from the canonical message record or its snapshot.
    private func persistPlainRoomLogMessage(
        message: V2AcceptedMessageDraft,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        commandWindowUsed: Int,
        entitiesJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: commandWindowUsed)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                  AND \(bind: persistsRoomAdmission)
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_id FROM room_update
                WHERE NOT \(bind: persistsRoomAdmission)
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_gate.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_gate
                RETURNING message_id, room_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'payload_storage', 'message_reference_v1',
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: Int64(message.createdAt.timeIntervalSince1970 * 1_000))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id
            )
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   0::bigint AS review_count,
                   0::bigint AS media_count,
                   0::bigint AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == 0,
              mutation.mediaCount == 0,
              mutation.mentionCount == 0,
              mutation.eventCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    private func assertAvailableMedia(_ media: [V2MediaReference], ownerID: UUID, now: Date, sql: any SQLDatabase) async throws -> [V2MediaPresentation] {
        guard !media.isEmpty else { return [] }
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        let requested = try media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let requestedJSON = try roomWriteJSON(requested)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT ordinal, media_id
                FROM jsonb_to_recordset(\(bind: requestedJSON)::jsonb)
                     AS input(ordinal integer, media_id uuid)
            )
            SELECT requested.ordinal, media.media_id, media.content_type, media.byte_count
            FROM requested
            JOIN im_v2.media_objects AS media
              ON media.media_id = requested.media_id
             AND media.owner_user_id = \(bind: ownerID)
             AND media.state = 'available'
             AND media.expires_at > \(bind: now)
            -- Lock shared media in a canonical order so two concurrent sends
            -- cannot deadlock merely because their attachment order differs.
            ORDER BY media.media_id
            FOR UPDATE OF media
            """).all(decoding: OrderedMessageMediaPresentationRow.self)
        let orderedRows = rows.sorted { $0.ordinal < $1.ordinal }
        guard orderedRows.count == requested.count,
              orderedRows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2MediaStoreError.mediaUnavailable }
        return try orderedRows.map { try $0.presentation }
    }

    private func assertMentionsAuthorized(_ mentions: [V2MentionTarget], roomID: UUID, membershipRevision: Int64, senderID: UUID, sql: any SQLDatabase) async throws {
        guard !mentions.isEmpty else { return }
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2MentionValidationError.invalidTargetSet }
        guard let sender = try await sql.raw("""
            SELECT role
            FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: senderID)
              AND joined_revision <= \(bind: membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: membershipRevision))
            FOR UPDATE
            """).first(decoding: MentionSenderMembershipRow.self),
              let role = V2RoomMembershipRole(rawValue: sender.role)
        else { throw V2RoomWriteStoreError.actorNotEligible }

        var mentionedUserIDs: [UUID] = []
        for target in mentions {
            guard case .user(let userID) = target else { continue }
            mentionedUserIDs.append(try uuid(userID))
        }
        let rows: [MentionMembershipRow]
        if mentionedUserIDs.isEmpty {
            rows = []
        } else {
            let targetJSON = try mentionTargetJSON(mentionedUserIDs)
            rows = try await sql.raw("""
                WITH targets AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: targetJSON)::jsonb) AS value
                )
                SELECT membership.user_id,
                       NOT EXISTS (
                         SELECT 1 FROM im_v2.user_blocks AS blocks
                         WHERE (blocks.blocker_user_id = \(bind: senderID) AND blocks.blocked_user_id = membership.user_id)
                            OR (blocks.blocker_user_id = membership.user_id AND blocks.blocked_user_id = \(bind: senderID))
                       ) AS mentionable
                FROM targets
                JOIN im_v2.room_memberships AS membership
                  ON membership.user_id = targets.user_id
                WHERE membership.room_id = \(bind: roomID)
                  AND membership.joined_revision <= \(bind: membershipRevision)
                  AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: membershipRevision))
                FOR UPDATE OF membership
                """).all(decoding: MentionMembershipRow.self)
        }
        let visibility = V2MentionVisibility(
            senderRole: role,
            visibleActiveUsers: Set(try rows.map { try UserID($0.userID.uuidString) }),
            mentionableUsers: Set(try rows.filter(\.mentionable).map { try UserID($0.userID.uuidString) })
        )
        try V2MentionAuthorization.authorize(mentions, visibility: visibility, limits: .init(maximumTargets: V2MessageCommandLimits.maxMentions))
    }

    private func assertReplyTarget(_ replyTo: V2MessageReplyReference?, roomID: UUID, sql: any SQLDatabase) async throws {
        guard let replyTo else { return }
        guard let targetID = UUID(uuidString: replyTo.messageID.rawValue),
              (try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.messages WHERE message_id = \(bind: targetID) AND room_id = \(bind: roomID)) AS authorized").first(decoding: AuthorizationRow.self)?.authorized ?? false)
        else { throw V2RoomWriteStoreError.replyTargetNotFound }
    }
}

private extension V2SendMessageAcceptanceResult {
    func outcome(
        mediaPresentations: [V2MediaPresentation] = [],
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false
    ) -> V2SendMessageOutcome {
        switch self {
        case .accepted:
            preconditionFailure("accepted transactions must be persisted before becoming a send outcome")
        case .idempotent(let message): .idempotent(message.materialized(
            mediaPresentations: mediaPresentations,
            groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog
        ))
        case .idempotencyConflict: .idempotencyConflict
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

private struct RoomRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    enum CodingKeys: String, CodingKey { case kind = "room_kind", roomShardID = "room_shard_id", roomSequence = "room_sequence", timelineSequence = "timeline_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode", frozenAt = "frozen_at" }

    func commandState(roomID: RoomID, admission: AdmissionRow) throws -> V2RoomCommandState {
        try .init(
            roomID: roomID,
            nextRoomSequence: UInt64(roomSequence) + 1,
            admission: admission.roomAdmissionState()
        )
    }
}

private func roomLogReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    reliableTargetCount: Int,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    let admission: FanoutAdmissionResult
    if reliableTargetCount == 0 {
        admission = try V2CommandOnlyAdmissionEvaluator.reserve(profile: profile, roomState: roomState.admission, shardState: shardState, now: now)
    } else {
        admission = try FanoutAdmissionEvaluator.reserve(
            request: .init(targetRule: .exactTargetCount(reliableTargetCount)),
            profile: profile,
            roomState: roomState.admission,
            shardState: shardState,
            now: now
        )
    }
    switch admission {
    case .rateLimited(let seconds):
        return .rateLimited(retryAfterSeconds: seconds)
    case .unavailable(let reason):
        return .unavailable(reason)
    case .accepted(let reservation, let nextAdmission, let nextShard):
        let accepted = V2AcceptedMessageDraft(
            messageID: identifiers.messageID,
            roomID: command.roomID,
            roomSequence: roomState.nextRoomSequence,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID,
            text: command.text,
            media: command.media,
            mentions: command.mentions,
            entities: command.entities,
            replyTo: command.replyTo,
            createdAt: now
        )
        let nextRoom = V2RoomCommandState(
            roomID: roomState.roomID,
            nextRoomSequence: roomState.nextRoomSequence + 1,
            admission: nextAdmission
        )
        return .accepted(.init(
            acceptedMessage: accepted,
            eventID: identifiers.eventID,
            fanoutPlan: .init(id: identifiers.planID, sourceEventID: identifiers.eventID, roomID: command.roomID, roomSequence: accepted.roomSequence, reservation: reservation),
            nextRoomState: nextRoom,
            nextShardState: nextShard
        ))
    }
}

/// Direct room-log delivery has a fixed two-user audience and does not create
/// a fan-out plan or outstanding-work reservation. In `shard_only` mode its
/// command budget is therefore the durable shard budget already used by the
/// admission-credit pool. The room admission value is carried forward
/// unchanged solely because the generic acceptance transaction still models
/// the next room sequence and admission state together.
///
/// Authorization is deliberately outside this helper and remains checked
/// against locked room, membership, direct-pair, policy-version and stranger
/// quota state by `PostgresV2RoomWriteStore.accept` before this reduction.
private func directRoomLogShardOnlyReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
    guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
    guard lease.commandWindow.canReserve(1) else {
        return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
    }

    let nextLease = try ShardAdmissionLease(
        id: lease.id,
        generation: lease.generation,
        validUntil: lease.validUntil,
        commandWindow: lease.commandWindow.reserving(1),
        fanoutWindow: lease.fanoutWindow,
        maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
        maxOutstandingPlans: lease.maxOutstandingPlans
    )
    let nextShard = try ShardAdmissionState(
        lease: nextLease,
        outstandingFanoutUnits: shardState.outstandingFanoutUnits,
        outstandingPlans: shardState.outstandingPlans
    )
    let accepted = V2AcceptedMessageDraft(
        messageID: identifiers.messageID,
        roomID: command.roomID,
        roomSequence: roomState.nextRoomSequence,
        senderUserID: command.senderUserID,
        clientMessageID: command.clientMessageID,
        text: command.text,
        media: command.media,
        mentions: command.mentions,
        entities: command.entities,
        replyTo: command.replyTo,
        createdAt: now
    )
    let nextRoom = V2RoomCommandState(
        roomID: roomState.roomID,
        nextRoomSequence: roomState.nextRoomSequence + 1,
        admission: roomState.admission
    )
    return .accepted(.init(
        acceptedMessage: accepted,
        eventID: identifiers.eventID,
        fanoutPlan: .init(
            id: identifiers.planID,
            sourceEventID: identifiers.eventID,
            roomID: command.roomID,
            roomSequence: accepted.roomSequence,
            reservation: .init(
                cost: try .init(targetCount: 0),
                shardLeaseID: lease.id,
                shardLeaseGeneration: lease.generation
            )
        ),
        nextRoomState: nextRoom,
        nextShardState: nextShard
    ))
}

// Kept as a narrow semantic wrapper while group hybrid still has explicit
// mention deliveries. Both paths share the command-only admission invariant
// when their canonical room event has no reliable projection targets.
private func hybridReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    reliableTargetCount: Int,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    try roomLogReduction(
        command: command,
        roomState: roomState,
        shardState: shardState,
        profile: profile,
        identifiers: identifiers,
        reliableTargetCount: reliableTargetCount,
        now: now
    )
}

private func hybridMentionTargetIDs(_ mentions: [V2MentionTarget], excluding senderID: UUID) -> [UUID] {
    Array(Set(mentions.compactMap { target -> UUID? in
        guard case .user(let userID) = target, let value = UUID(uuidString: userID.rawValue), value != senderID else { return nil }
        return value
    })).sorted { $0.uuidString < $1.uuidString }
}

private func mentionTargetJSON(_ userIDs: [UUID]) throws -> String {
    let values = userIDs.map(\.uuidString)
    let data = try JSONEncoder().encode(values)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private func roomWriteJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private struct OrderedMediaReferenceInput: Encodable {
    let ordinal: Int
    let mediaID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
    }
}

private struct OrderedMentionInput: Encodable {
    let ordinal: Int
    let mentionKind: String
    let mentionedUserID: UUID?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mentionKind = "mention_kind"
        case mentionedUserID = "mentioned_user_id"
    }
}

/// The one-row result of the send preflight CTE. `locked_room` is always
/// present; every other group is optional because idempotent replay must not
/// take fresh-send locks or policy decisions after its durable result exists.
private struct MessageAcceptanceContextRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    let priorOperationCount: Int
    let priorOutcomeKind: String?
    let priorMessageID: UUID?
    let priorRoomID: UUID?
    let priorRoomSequence: Int64?
    let priorTimelineSequence: Int64?
    let priorSenderUserID: UUID?
    let priorClientMessageID: UUID?
    let priorTextBody: String?
    let priorRichEntities: String?
    let priorReplyToMessageID: UUID?
    let priorCreatedAt: Date?
    let priorSourceEventID: UUID?
    let priorDenialReason: String?
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
    let roomFanoutWindowLimit: Int?
    let roomFanoutWindowUsed: Int?
    let roomMaxOutstandingFanoutUnits: Int?
    let roomOutstandingFanoutUnits: Int?
    let roomMaxOutstandingPlans: Int?
    let roomOutstandingPlans: Int?
    let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
    let shardFanoutWindowLimit: Int?
    let shardFanoutWindowUsed: Int?
    let shardMaxOutstandingFanoutUnits: Int?
    let shardOutstandingFanoutUnits: Int?
    let shardMaxOutstandingPlans: Int?
    let shardOutstandingPlans: Int?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderProfileVisibleToRecipient: Bool?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case deliveryMode = "delivery_mode"
        case frozenAt = "frozen_at"
        case priorOperationCount = "prior_operation_count"
        case priorOutcomeKind = "prior_outcome_kind"
        case priorMessageID = "prior_message_id"
        case priorRoomID = "prior_room_id"
        case priorRoomSequence = "prior_room_sequence"
        case priorTimelineSequence = "prior_timeline_sequence"
        case priorSenderUserID = "prior_sender_user_id"
        case priorClientMessageID = "prior_client_message_id"
        case priorTextBody = "prior_text_body"
        case priorRichEntities = "prior_rich_entities"
        case priorReplyToMessageID = "prior_reply_to_message_id"
        case priorCreatedAt = "prior_created_at"
        case priorSourceEventID = "prior_source_event_id"
        case priorDenialReason = "prior_denial_reason"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"
        case roomFanoutWindowLimit = "room_fanout_window_limit"
        case roomFanoutWindowUsed = "room_fanout_window_used"
        case roomMaxOutstandingFanoutUnits = "room_max_outstanding_fanout_units"
        case roomOutstandingFanoutUnits = "room_outstanding_fanout_units"
        case roomMaxOutstandingPlans = "room_max_outstanding_plans"
        case roomOutstandingPlans = "room_outstanding_plans"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"
        case shardFanoutWindowLimit = "shard_fanout_window_limit"
        case shardFanoutWindowUsed = "shard_fanout_window_used"
        case shardMaxOutstandingFanoutUnits = "shard_max_outstanding_fanout_units"
        case shardOutstandingFanoutUnits = "shard_outstanding_fanout_units"
        case shardMaxOutstandingPlans = "shard_max_outstanding_plans"
        case shardOutstandingPlans = "shard_outstanding_plans"
        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case recipientUserID = "recipient_user_id"
        case directPolicyRevision = "direct_policy_revision"
        case senderPolicyRevision = "sender_policy_revision"
        case recipientPolicyRevision = "recipient_policy_revision"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            deliveryMode: deliveryMode,
            frozenAt: frozenAt
        )
    }

    func existingOperation() throws -> ExistingMessageOperation? {
        guard let priorOutcomeKind else {
            guard priorMessageID == nil, priorRoomID == nil,
                  priorRoomSequence == nil, priorTimelineSequence == nil,
                  priorSenderUserID == nil, priorClientMessageID == nil,
                  priorTextBody == nil, priorRichEntities == nil,
                  priorReplyToMessageID == nil, priorCreatedAt == nil,
                  priorSourceEventID == nil, priorDenialReason == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return nil
        }
        guard let priorRoomID, let priorTimelineSequence, let priorSenderUserID,
              let priorClientMessageID, let priorCreatedAt
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try MessageOperationReplayRow(
            outcomeKind: priorOutcomeKind,
            messageID: priorMessageID,
            roomID: priorRoomID,
            roomSequence: priorRoomSequence,
            timelineSequence: priorTimelineSequence,
            senderUserID: priorSenderUserID,
            clientMessageID: priorClientMessageID,
            textBody: priorTextBody,
            richEntities: priorRichEntities,
            replyToMessageID: priorReplyToMessageID,
            createdAt: priorCreatedAt,
            sourceEventID: priorSourceEventID,
            denialReason: priorDenialReason
        ).operation()
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomFanoutWindowLimit,
              let roomFanoutWindowUsed, let roomMaxOutstandingFanoutUnits,
              let roomOutstandingFanoutUnits, let roomMaxOutstandingPlans,
              let roomOutstandingPlans, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed,
              let shardFanoutWindowLimit, let shardFanoutWindowUsed,
              let shardMaxOutstandingFanoutUnits,
              let shardOutstandingFanoutUnits, let shardMaxOutstandingPlans,
              let shardOutstandingPlans
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,
            roomFanoutWindowLimit: roomFanoutWindowLimit,
            roomFanoutWindowUsed: roomFanoutWindowUsed,
            roomMaxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            roomOutstandingFanoutUnits: roomOutstandingFanoutUnits,
            roomMaxOutstandingPlans: roomMaxOutstandingPlans,
            roomOutstandingPlans: roomOutstandingPlans,
            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,
            shardFanoutWindowLimit: shardFanoutWindowLimit,
            shardFanoutWindowUsed: shardFanoutWindowUsed,
            shardMaxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            shardOutstandingFanoutUnits: shardOutstandingFanoutUnits,
            shardMaxOutstandingPlans: shardMaxOutstandingPlans,
            shardOutstandingPlans: shardOutstandingPlans,
            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied, let allowsStrangers
        else { throw V2RoomWriteStoreError.actorNotEligible }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() -> V2DirectSendPolicyCache.Entry? {
        guard kind == "direct",
              let recipientUserID, let directPolicyRevision,
              let senderPolicyRevision, let recipientPolicyRevision,
              let senderProfileVisibleToRecipient, let recipientIsActive,
              let blocked, let isFriend, let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { return nil }
        return .init(
            recipientID: recipientUserID,
            directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }
}

private struct AdmissionSnapshotRow: Decodable {
    let roomEligibleMemberCount: Int
    let roomCommandWindowLimit: Int
    let roomCommandWindowUsed: Int
    let roomFanoutWindowLimit: Int
    let roomFanoutWindowUsed: Int
    let roomMaxOutstandingFanoutUnits: Int
    let roomOutstandingFanoutUnits: Int
    let roomMaxOutstandingPlans: Int
    let roomOutstandingPlans: Int
    let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shardLeaseID: UUID
    let shardGeneration: Int64
    let shardValidUntil: Date
    let shardCommandWindowLimit: Int
    let shardCommandWindowUsed: Int
    let shardFanoutWindowLimit: Int
    let shardFanoutWindowUsed: Int
    let shardMaxOutstandingFanoutUnits: Int
    let shardOutstandingFanoutUnits: Int
    let shardMaxOutstandingPlans: Int
    let shardOutstandingPlans: Int
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?

    var room: AdmissionRow {
        .init(
            eligibleMemberCount: roomEligibleMemberCount,
            commandWindowLimit: roomCommandWindowLimit,
            commandWindowUsed: roomCommandWindowUsed,
            fanoutWindowLimit: roomFanoutWindowLimit,
            fanoutWindowUsed: roomFanoutWindowUsed,
            maxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            outstandingFanoutUnits: roomOutstandingFanoutUnits,
            maxOutstandingPlans: roomMaxOutstandingPlans,
            outstandingPlans: roomOutstandingPlans,
            shardLeaseID: roomShardLeaseID,
            shardLeaseGeneration: roomShardLeaseGeneration
        )
    }

    var shard: ShardRow {
        .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed,
            fanoutWindowLimit: shardFanoutWindowLimit,
            fanoutWindowUsed: shardFanoutWindowUsed,
            maxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            outstandingFanoutUnits: shardOutstandingFanoutUnits,
            maxOutstandingPlans: shardMaxOutstandingPlans,
            outstandingPlans: shardOutstandingPlans
        )
    }

    enum CodingKeys: String, CodingKey {
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"
        case roomFanoutWindowLimit = "room_fanout_window_limit"
        case roomFanoutWindowUsed = "room_fanout_window_used"
        case roomMaxOutstandingFanoutUnits = "room_max_outstanding_fanout_units"
        case roomOutstandingFanoutUnits = "room_outstanding_fanout_units"
        case roomMaxOutstandingPlans = "room_max_outstanding_plans"
        case roomOutstandingPlans = "room_outstanding_plans"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"
        case shardFanoutWindowLimit = "shard_fanout_window_limit"
        case shardFanoutWindowUsed = "shard_fanout_window_used"
        case shardMaxOutstandingFanoutUnits = "shard_max_outstanding_fanout_units"
        case shardOutstandingFanoutUnits = "shard_outstanding_fanout_units"
        case shardMaxOutstandingPlans = "shard_max_outstanding_plans"
        case shardOutstandingPlans = "shard_outstanding_plans"
        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
    }
}

private struct AdmissionRow: Decodable {
    let eligibleMemberCount: Int
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey {
        case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation"
    }
    func roomAdmissionState() throws -> RoomAdmissionState {
        try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans)
    }
}

private struct ShardRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans"
    }
    func admissionState() throws -> ShardAdmissionState {
        try .init(lease: .init(id: try ShardAdmissionLeaseID(leaseID.uuidString), generation: try unsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans)
    }
}

private enum LateShardAdmissionRejection: Error, Sendable {
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

private struct ShardAdmissionMutationRow: Decodable {
    let applied: Int
}

private struct ShardAdmissionReservation: Sendable {
    let leaseID: UUID
    let generation: Int64
    let commandDelta: Int
    let fanoutDelta: Int
    let outstandingUnitDelta: Int
    let outstandingPlanDelta: Int
}

private struct CurrentShardLeaseRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation
        case validUntil = "valid_until"
    }
}

private struct SetBasedRoomWriteMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64
    let messageStateCount: Int64
    let sharedPayloadCount: Int64
    let planCount: Int64
    let outboxCount: Int64
    let directTargetCount: Int64
    let directRoutedCount: Int64
    let completionCount: Int64
    let deliveryCount: Int64
    let preplannedPlanCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
        case messageStateCount = "message_state_count"
        case sharedPayloadCount = "shared_payload_count"
        case planCount = "plan_count"
        case outboxCount = "outbox_count"
        case directTargetCount = "direct_target_count"
        case directRoutedCount = "direct_routed_count"
        case completionCount = "completion_count"
        case deliveryCount = "delivery_count"
        case preplannedPlanCount = "preplanned_plan_count"
    }
}

private struct RoomLogMessageMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
    }
}

private struct MessageRow: Decodable {
    let messageID: UUID
    let roomID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let textBody: String
    let richEntities: String
    let replyToMessageID: UUID?
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case messageID = "message_id", roomID = "room_id", roomSequence = "room_sequence", timelineSequence = "timeline_sequence", senderUserID = "sender_user_id", clientMessageID = "client_message_id", textBody = "text_body", richEntities = "rich_entities", replyToMessageID = "reply_to_message_id", createdAt = "created_at" }
    func acceptedMessage(
        media: [V2MediaReference] = [],
        mediaPresentations: [V2MediaPresentation] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false
    ) throws -> V2AcceptedMessage {
        let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(richEntities.utf8))
        try V2RichMessageContent.validate(text: textBody, entities: entities)
        let replyTo: V2MessageReplyReference?
        if let replyToMessageID {
            replyTo = .init(messageID: try .init(replyToMessageID.uuidString))
        } else {
            replyTo = nil
        }
        return try .init(messageID: .init(messageID.uuidString), roomID: .init(roomID.uuidString), roomSequence: unsigned(roomSequence), timelineSequence: unsigned(timelineSequence), senderUserID: .init(senderUserID.uuidString), clientMessageID: .init(clientMessageID.uuidString), text: textBody, media: media, mediaPresentations: mediaPresentations, mentions: mentions, entities: entities, replyTo: replyTo, groupDeliveryMode: groupDeliveryMode, usesRoomEventLog: usesRoomEventLog, createdAt: createdAt)
    }
}

private struct AuthorizationRow: Decodable { let authorized: Bool }
private struct DirectRoomPairRow: Decodable {
    let lowerUserID: UUID
    let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct DirectPolicyBooleanRow: Decodable { let value: Bool }
private struct DirectMessageAcceptanceContext {
    let recipientID: UUID
    let restriction: V2DirectMessageDenied.Reason?
    let requiresStrangerQuota: Bool
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let senderHasReplied: Bool
    let supportAccountID: UUID?
}
private struct RoomWriteCommit {
    let outcome: V2SendMessageOutcome
    /// `nil` means an idempotent acceptance must recover shadowing from the
    /// committed source rows. A non-nil array is the exact delta from a new
    /// transaction; an empty array deliberately skips all post-commit reads.
    let acceptedDirectProjectionShadows: [DirectProjectionShadowRequest]?
    let directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry?
    /// A command credit becomes committed only after this transaction returns
    /// successfully from Fluent. All non-success paths return it to the local
    /// pool from inside the retry closure.
    let shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token?

    init(
        outcome: V2SendMessageOutcome,
        acceptedDirectProjectionShadows: [DirectProjectionShadowRequest]?,
        directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry? = nil,
        shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token? = nil
    ) {
        self.outcome = outcome
        self.acceptedDirectProjectionShadows = acceptedDirectProjectionShadows
        self.directPolicyCacheUpdate = directPolicyCacheUpdate
        self.shardAdmissionCommandCredit = shardAdmissionCommandCredit
    }
}
private struct DirectProjectionShadowRequest {
    let userID: UserID
    let sourceEventID: EventID
    let projectionKinds: Set<String>
}
private struct DirectPostAcceptanceProjectionChanges {
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
}
private struct DirectMessagePolicySnapshotRow: Decodable {
    let recipientUserID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let recipientIsActive: Bool
    let blocked: Bool
    let isFriend: Bool
    let senderHasReplied: Bool
    let recipientHasReplied: Bool
    let allowsStrangers: Bool
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "recipient_user_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }
}
private struct DirectRoomProfileMutationRow: Decodable {
    let profileExists: Bool
    let neededCount: Int64
    let profileInsertedCount: Int64
    let insertedCount: Int64
    let pairCount: Int64

    enum CodingKeys: String, CodingKey {
        case profileExists = "profile_exists"
        case neededCount = "needed_count"
        case profileInsertedCount = "profile_inserted_count"
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectCapabilityMutationRow: Decodable {
    let insertedCount: Int64
    let pairCount: Int64
    enum CodingKeys: String, CodingKey {
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectMessageSyncSequenceRow: Decodable {
    let nextSequence: Int64
    enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" }
}
private struct DirectMessageEventRow: Decodable {
    let eventID: UUID
    enum CodingKeys: String, CodingKey { case eventID = "event_id" }
}
private enum ExistingMessageOperation {
    case accepted(MessageRow)
    case denied(V2DirectMessageDenied)
}
private struct MessageOperationReplayRow: Decodable {
    let outcomeKind: String
    let messageID: UUID?
    let roomID: UUID
    let roomSequence: Int64?
    let timelineSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let textBody: String?
    let richEntities: String?
    let replyToMessageID: UUID?
    let createdAt: Date
    let sourceEventID: UUID?
    let denialReason: String?

    enum CodingKeys: String, CodingKey {
        case outcomeKind = "outcome_kind"
        case messageID = "message_id"
        case roomID = "room_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case senderUserID = "sender_user_id"
        case clientMessageID = "client_message_id"
        case textBody = "text_body"
        case richEntities = "rich_entities"
        case replyToMessageID = "reply_to_message_id"
        case createdAt = "created_at"
        case sourceEventID = "source_event_id"
        case denialReason = "denial_reason"
    }

    func operation() throws -> ExistingMessageOperation {
        switch outcomeKind {
        case "accepted":
            guard let messageID, let roomSequence, let textBody, let richEntities,
                  sourceEventID == nil, denialReason == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .accepted(.init(
                messageID: messageID,
                roomID: roomID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                senderUserID: senderUserID,
                clientMessageID: clientMessageID,
                textBody: textBody,
                richEntities: richEntities,
                replyToMessageID: replyToMessageID,
                createdAt: createdAt
            ))
        case "denied":
            guard messageID == nil, roomSequence == nil, textBody == nil,
                  richEntities == nil, replyToMessageID == nil,
                  let sourceEventID, let denialReason,
                  let reason = V2DirectMessageDenied.Reason(rawValue: denialReason)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .denied(try .init(
                roomID: .init(roomID.uuidString),
                sourceEventID: .init(sourceEventID.uuidString),
                timelineSequence: unsigned(timelineSequence),
                createdAt: createdAt,
                reason: reason
            ))
        default:
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
private struct DirectReplyMarkerMutationRow: Decodable { let roomID: UUID; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
private struct MessageMediaPresentationRow: Decodable {
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(mediaID.uuidString),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct OrderedMessageMediaPresentationRow: Decodable {
    let ordinal: Int
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(mediaID.uuidString),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct MentionSenderMembershipRow: Decodable { let role: String }
private struct ForwardSourceRow: Decodable { let roomID: UUID; let senderUserID: UUID; let text: String; let withdrawnAt: Date?; let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", text = "text_body", withdrawnAt = "withdrawn_at", membershipRevision = "membership_revision" } }
private struct ForwardMediaRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct ForwardVisibilityRow: Decodable { let value: Bool }
private struct MentionMembershipRow: Decodable { let userID: UUID; let mentionable: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", mentionable } }
private struct MentionRow: Decodable {
    let kind: String; let userID: UUID?
    enum CodingKeys: String, CodingKey { case kind = "mention_kind", userID = "mentioned_user_id" }
    var target: V2MentionTarget {
        get throws {
            switch kind {
            case "everyone": return .everyone
            case "user": guard let userID else { throw V2RoomWriteStoreError.corruptPersistenceState }; return .user(try .init(userID.uuidString))
            default: throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
    }
}

private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: value.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}

private func targetRuleJSON(_ cost: FanoutCost, commandRule: FanoutTargetRule?) -> String {
    switch commandRule {
    case .exactTargetCount(_:): return "{\"kind\":\"exact_target_count\",\"count\":\(cost.targetCount)}"
    case .eligibleMemberCount, .none: return "{\"kind\":\"eligible_member_count\"}"
    }
}
