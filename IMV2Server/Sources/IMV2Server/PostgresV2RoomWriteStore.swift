import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL implementation of the V2 acceptance boundary.
///
/// Lock order is fixed as `rooms -> room_admission -> shard_admission_pools
/// -> room_memberships -> media_objects`. The reducer runs while the admission
/// rows are locked and every successful value is committed by the same
/// database transaction.
public struct PostgresV2RoomWriteStore: V2RoomWriteStore {
    private let database: any Database
    private let strangerMessagePolicy: V2StrangerMessagePolicy?
    private let shadowForwarder: (any V2UserShardProjectionShadowing)?

    public init(
        database: any Database,
        strangerMessagePolicy: V2StrangerMessagePolicy? = nil,
        shadowForwarder: (any V2UserShardProjectionShadowing)? = nil
    ) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
        self.shadowForwarder = shadowForwarder
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        let outcome: V2SendMessageOutcome = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let roomID = try uuid(command.roomID)
            let senderID = try uuid(command.senderUserID)
            let clientMessageID = try uuid(command.clientMessageID)

            guard let room = try await sql.raw("""
                SELECT room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, delivery_mode, frozen_at
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: RoomRow.self)
            else {
                throw V2RoomWriteStoreError.roomNotFound
            }
            guard room.capacityProfileID == capacityProfile.id else {
                throw V2RoomWriteStoreError.capacityProfileMismatch
            }

            // A completed command must replay its canonical result even if a
            // later membership change removes the sender. Otherwise a lost
            // acceptance response becomes an observable false rejection and
            // clients cannot safely retain their immutable operation ID.
            if let existing = try await sql.raw("""
                SELECT message_id, room_id, room_sequence, sender_user_id,
                       client_message_id, text_body, rich_entities::text AS rich_entities,
                       reply_to_message_id, created_at
                FROM im_v2.messages
                WHERE sender_user_id = \(bind: senderID)
                  AND client_message_id = \(bind: clientMessageID)
                """).first(decoding: MessageRow.self) {
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
                    groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil
                )
                return accepted.roomID == command.roomID && accepted.text == command.text && accepted.media == command.media && accepted.mentions == command.mentions
                    && accepted.entities == command.entities && accepted.replyTo == command.replyTo
                    ? .idempotent(accepted)
                    : .idempotencyConflict
            }
            guard room.frozenAt == nil else {
                throw V2RoomWriteStoreError.roomFrozen
            }
            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                       outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: AdmissionRow.self),
                  let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit,
                       command_window_used, fanout_window_limit, fanout_window_used,
                       max_outstanding_fanout_units, outstanding_fanout_units,
                       max_outstanding_plans, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID)
                  AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: ShardRow.self)
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let actor = try await sql.raw("""
                SELECT role
                FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID)
                  AND user_id = \(bind: senderID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                FOR UPDATE
                """).first(decoding: MembershipRoleRow.self),
                let actorRole = V2RoomMembershipRole(rawValue: actor.role)
            else {
                throw V2RoomWriteStoreError.actorNotEligible
            }
            if room.kind == "group" {
                let configuredPermissions = try await v2ResolvedGroupPermissions(roomID: roomID, role: actorRole, sql: sql)
                guard V2GroupPermissionDefaults.allows(role: actorRole, permission: .sendMessages, configured: configuredPermissions) else {
                    throw V2RoomWriteStoreError.actorNotEligible
                }
            }
            let actorIsMuted = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM im_v2.room_member_mutes
                    WHERE room_id = \(bind: roomID) AND user_id = \(bind: senderID)
                      AND mute_until > \(bind: now)
                ) AS muted
                """).first(decoding: MuteAuthorizationRow.self)?.muted ?? false
            guard !actorIsMuted else {
                throw V2RoomWriteStoreError.actorMuted
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
            let result: V2SendMessageAcceptanceResult
            switch room.deliveryMode {
            case .standardFanout:
                result = try V2SendMessageReducer.reduce(
                    command: command,
                    roomState: roomState,
                    shardState: shardState,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    now: now
                )
            case .largeGroupHybrid:
                result = try hybridReduction(
                    command: command,
                    roomState: roomState,
                    shardState: shardState,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    reliableTargetCount: hybridReliableTargets.count,
                    now: now
                )
            }
            guard case .accepted(let writeSet) = result else {
                return result.outcome(
                    mediaPresentations: mediaPresentations,
                    groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil
                )
            }
            // Do this only after the generic admission reducer accepts. A
            // capacity rejection returns normally from this transaction, so
            // consuming the stranger window earlier would be a silent quota
            // loss despite no accepted message.
            if room.kind == "direct" {
                guard let strangerMessagePolicy else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await enforceDirectMessagePolicy(roomID: roomID, senderID: senderID, policy: strangerMessagePolicy, now: now, sql: sql)
            }

            try await persist(writeSet, command: command, mediaPresentations: mediaPresentations, room: room, sql: sql)
            if room.kind == "direct" {
                try await appendRecipientDirectRoomProfile(
                    roomID: roomID,
                    senderID: senderID,
                    sourceEventID: try uuid(writeSet.eventID),
                    createdAt: writeSet.acceptedMessage.createdAt,
                    sql: sql
                )
            }
            let message = writeSet.acceptedMessage
            // The room row is locked for this transaction, so this metadata
            // is exactly the immutable mode that committed the event.  It is
            // used only to avoid emitting foreground-group hints for direct
            // rooms after the source transaction succeeds.
            return .accepted(message.materialized(
                mediaPresentations: mediaPresentations,
                groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil
            ))
        }
        try await shadowDirectRoomProfileIfNeeded(command: command, outcome: outcome)
        return outcome
    }

    /// The control store remains the source of truth for direct-profile
    /// visibility. Once a first direct message commits, mirror that profile
    /// to the recipient's live user shard just as the direct-open path does.
    /// Running this after the transaction is deliberate: a retry of the same
    /// immutable client message repeats the idempotent shadow if a process
    /// crashed after commit but before forwarding.
    private func shadowDirectRoomProfileIfNeeded(
        command _: V2SendMessageCommand,
        outcome: V2SendMessageOutcome
    ) async throws {
        guard let shadowForwarder else { return }
        let message: V2AcceptedMessage
        switch outcome {
        case .accepted(let value), .idempotent(let value):
            message = value
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
    }

    /// Runs after durable message idempotency and membership authorization. A
    /// retry therefore returns the committed result without consuming quota,
    /// and a non-member cannot probe a direct pair's policy state.
    private func enforceDirectMessagePolicy(roomID: UUID, senderID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
        guard let pair = try await sql.raw("SELECT lower_user_id, higher_user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: DirectRoomPairRow.self) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let recipientID: UUID
        if pair.lowerUserID == senderID { recipientID = pair.higherUserID }
        else if pair.higherUserID == senderID { recipientID = pair.lowerUserID }
        else { throw V2RoomWriteStoreError.actorNotEligible }

        let blocked = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_blocks WHERE (blocker_user_id = \(bind: senderID) AND blocked_user_id = \(bind: recipientID)) OR (blocker_user_id = \(bind: recipientID) AND blocked_user_id = \(bind: senderID))) AS value").first(decoding: DirectPolicyBooleanRow.self)?.value ?? true
        guard !blocked else { throw V2RoomWriteStoreError.directMessageBlocked }
        let isFriend = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lowerUserID) AND higher_user_id = \(bind: pair.higherUserID) AND state = 'accepted') AS value").first(decoding: DirectPolicyBooleanRow.self)?.value ?? false
        let hasRecipientReplied = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.messages WHERE room_id = \(bind: roomID) AND sender_user_id = \(bind: recipientID)) AS value").first(decoding: DirectPolicyBooleanRow.self)?.value ?? false
        guard !isFriend && !hasRecipientReplied else { return }
        let allowsStrangers = try await sql.raw("SELECT COALESCE((SELECT allows_stranger_messages FROM im_v2.user_stranger_message_preferences WHERE user_id = \(bind: recipientID)), TRUE) AS value").first(decoding: DirectPolicyBooleanRow.self)?.value ?? false
        guard allowsStrangers else { throw V2RoomWriteStoreError.strangerMessagePermissionDenied }
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

    /// Makes an unopened direct pair visible to the recipient only after its
    /// first message has passed block, stranger-preference and quota checks in
    /// this same transaction. The profile precedes the asynchronous message
    /// fan-out in that recipient's sync stream, so a delivered first message
    /// always has a stable conversation identity.
    private func appendRecipientDirectRoomProfile(roomID: UUID, senderID: UUID, sourceEventID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        guard let pair = try await sql.raw("SELECT lower_user_id, higher_user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: roomID)").first(decoding: DirectRoomPairRow.self) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let recipientID: UUID
        if pair.lowerUserID == senderID { recipientID = pair.higherUserID }
        else if pair.higherUserID == senderID { recipientID = pair.lowerUserID }
        else { throw V2RoomWriteStoreError.actorNotEligible }
        let alreadyVisible = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.user_sync_log
                WHERE user_id = \(bind: recipientID) AND projection_kind = 'direct_room_profile'
                  AND payload->>'room_id' = \(bind: roomID.uuidString)
            ) AS value
            """).first(decoding: DirectPolicyBooleanRow.self)?.value ?? false
        guard !alreadyVisible else { return }
        guard let profile = try await sql.raw("""
            SELECT public_handle, display_name, revision, updated_at
            FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderID)
            """).first(decoding: DirectMessageSenderProfileRow.self), profile.revision > 0 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sequence = try await sql.raw("""
            INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
            VALUES (\(bind: recipientID), 1)
            ON CONFLICT (user_id) DO UPDATE
            SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1
            RETURNING next_sequence
            """).first(decoding: DirectMessageSyncSequenceRow.self) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await sql.raw("""
            INSERT INTO im_v2.user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
            VALUES (\(bind: recipientID), \(bind: sequence.nextSequence), \(bind: sourceEventID), 'direct_room_profile',
                    jsonb_build_object('room_id', \(bind: roomID.uuidString), 'target_user_id', \(bind: senderID.uuidString),
                                       'public_handle', \(bind: profile.publicHandle), 'display_name', \(bind: profile.displayName),
                                       'revision', \(bind: profile.revision), 'updated_at_ms', \(bind: Int64(profile.updatedAt.timeIntervalSince1970 * 1_000))),
                    \(bind: createdAt))
            """).run()
    }

    private func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        mediaPresentations: [V2MediaPresentation],
        room: RoomRow,
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
        let roomAdmission = writeSet.nextRoomState.admission
        let shardState = writeSet.nextShardState
        guard let shardLease = shardState.lease else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let shardLeaseID = try uuid(shardLease.id)
        let shardLeaseGeneration = try signed(shardLease.generation)

        try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence)
            WHERE room_id = \(bind: roomID)
            """).run()
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
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = \(bind: shardLease.commandWindow.used),
                fanout_window_used = \(bind: shardLease.fanoutWindow.used),
                outstanding_fanout_units = \(bind: shardState.outstandingFanoutUnits),
                outstanding_plans = \(bind: shardState.outstandingPlans)
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: shardLeaseID)
              AND generation = \(bind: shardLeaseGeneration)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, sender_user_id, client_message_id, text_body, rich_entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: entitiesJSON)::jsonb, NULLIF(\(bind: replyToMessageID), '')::uuid, \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID), \(bind: message.createdAt))
            """).run()
        for (ordinal, reference) in message.media.enumerated() {
            try await sql.raw("INSERT INTO im_v2.message_media_references (message_id, media_id, ordinal, referenced_at) VALUES (\(bind: messageID), \(bind: try uuid(reference.mediaID)), \(bind: ordinal), \(bind: message.createdAt))").run()
        }
        for (ordinal, target) in message.mentions.enumerated() {
            switch target {
            case .user(let userID):
                try await sql.raw("INSERT INTO im_v2.message_mentions (message_id, ordinal, mention_kind, mentioned_user_id, created_at) VALUES (\(bind: messageID), \(bind: ordinal), 'user', \(bind: try uuid(userID)), \(bind: message.createdAt))").run()
            case .everyone:
                try await sql.raw("INSERT INTO im_v2.message_mentions (message_id, ordinal, mention_kind, mentioned_user_id, created_at) VALUES (\(bind: messageID), \(bind: ordinal), 'everyone', NULL, \(bind: message.createdAt))").run()
            }
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
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: room.membershipRevision),
                     \(bind: targetRuleJSON(writeSet.fanoutPlan.reservation.cost, commandRule: command.targetRule))::jsonb,
                     jsonb_build_object('after_user_id', NULL),
                     \(bind: writeSet.fanoutPlan.reservation.cost.targetCount), \(bind: writeSet.fanoutPlan.reservation.cost.targetCount), 'planning', \(bind: message.createdAt))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at)
                VALUES (\(bind: eventID), \(bind: planID), 'pending', \(bind: message.createdAt))
                """).run()
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
    }

    private func assertAvailableMedia(_ media: [V2MediaReference], ownerID: UUID, now: Date, sql: any SQLDatabase) async throws -> [V2MediaPresentation] {
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        var presentations: [V2MediaPresentation] = []
        for reference in media {
            let mediaID = try uuid(reference.mediaID)
            guard let row = try await sql.raw("SELECT media_id, content_type, byte_count FROM im_v2.media_objects WHERE media_id = \(bind: mediaID) AND owner_user_id = \(bind: ownerID) AND state = 'available' AND expires_at > \(bind: now) FOR UPDATE").first(decoding: MessageMediaPresentationRow.self) else { throw V2MediaStoreError.mediaUnavailable }
            presentations.append(try row.presentation)
        }
        return presentations
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
        groupDeliveryMode: V2GroupDeliveryMode? = nil
    ) -> V2SendMessageOutcome {
        switch self {
        case .accepted:
            preconditionFailure("accepted transactions must be persisted before becoming a send outcome")
        case .idempotent(let message): .idempotent(message.materialized(
            mediaPresentations: mediaPresentations,
            groupDeliveryMode: groupDeliveryMode
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
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    enum CodingKeys: String, CodingKey { case kind = "room_kind", roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode", frozenAt = "frozen_at" }

    func commandState(roomID: RoomID, admission: AdmissionRow) throws -> V2RoomCommandState {
        try .init(
            roomID: roomID,
            nextRoomSequence: UInt64(roomSequence) + 1,
            admission: admission.roomAdmissionState()
        )
    }
}

private func hybridReduction(
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

private struct MessageRow: Decodable {
    let messageID: UUID
    let roomID: UUID
    let roomSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let textBody: String
    let richEntities: String
    let replyToMessageID: UUID?
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case messageID = "message_id", roomID = "room_id", roomSequence = "room_sequence", senderUserID = "sender_user_id", clientMessageID = "client_message_id", textBody = "text_body", richEntities = "rich_entities", replyToMessageID = "reply_to_message_id", createdAt = "created_at" }
    func acceptedMessage(
        media: [V2MediaReference] = [],
        mediaPresentations: [V2MediaPresentation] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil
    ) throws -> V2AcceptedMessage {
        let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(richEntities.utf8))
        try V2RichMessageContent.validate(text: textBody, entities: entities)
        let replyTo: V2MessageReplyReference?
        if let replyToMessageID {
            replyTo = .init(messageID: try .init(replyToMessageID.uuidString))
        } else {
            replyTo = nil
        }
        return try .init(messageID: .init(messageID.uuidString), roomID: .init(roomID.uuidString), roomSequence: unsigned(roomSequence), senderUserID: .init(senderUserID.uuidString), clientMessageID: .init(clientMessageID.uuidString), text: textBody, media: media, mediaPresentations: mediaPresentations, mentions: mentions, entities: entities, replyTo: replyTo, groupDeliveryMode: groupDeliveryMode, createdAt: createdAt)
    }
}

private struct MembershipRoleRow: Decodable { let role: String }
private struct AuthorizationRow: Decodable { let authorized: Bool }
private struct MuteAuthorizationRow: Decodable { let muted: Bool }
private struct DirectRoomPairRow: Decodable {
    let lowerUserID: UUID
    let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct DirectPolicyBooleanRow: Decodable { let value: Bool }
private struct DirectMessageSenderProfileRow: Decodable {
    let publicHandle: String
    let displayName: String
    let revision: Int64
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case revision
        case updatedAt = "updated_at"
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
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
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
