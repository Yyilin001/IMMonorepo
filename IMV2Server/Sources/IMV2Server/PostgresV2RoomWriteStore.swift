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

    public init(database: any Database, strangerMessagePolicy: V2StrangerMessagePolicy? = nil) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        try await database.transaction { transaction in
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
                       client_message_id, text_body, created_at
                FROM im_v2.messages
                WHERE sender_user_id = \(bind: senderID)
                  AND client_message_id = \(bind: clientMessageID)
                """).first(decoding: MessageRow.self) {
                let priorMedia = try await sql.raw("SELECT media_id FROM im_v2.message_media_references WHERE message_id = \(bind: existing.messageID) ORDER BY ordinal").all(decoding: MediaReferenceRow.self)
                let priorMentions = try await sql.raw("SELECT mention_kind, mentioned_user_id FROM im_v2.message_mentions WHERE message_id = \(bind: existing.messageID) ORDER BY ordinal").all(decoding: MentionRow.self)
                let accepted = try existing.acceptedMessage(
                    media: priorMedia.map { try .init(mediaID: .init($0.mediaID.uuidString)) },
                    mentions: try priorMentions.map { try $0.target },
                    groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil
                )
                return accepted.roomID == command.roomID && accepted.text == command.text && accepted.media == command.media && accepted.mentions == command.mentions
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
            let actorIsEligible = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1
                    FROM im_v2.room_memberships
                    WHERE room_id = \(bind: roomID)
                      AND user_id = \(bind: senderID)
                      AND joined_revision <= \(bind: room.membershipRevision)
                      AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                ) AS authorized
                """).first(decoding: AuthorizationRow.self)?.authorized ?? false
            guard actorIsEligible else {
                throw V2RoomWriteStoreError.actorNotEligible
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
            try await assertAvailableMedia(command.media, ownerID: senderID, now: now, sql: sql)
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
                return result.outcome
            }
            // Do this only after the generic admission reducer accepts. A
            // capacity rejection returns normally from this transaction, so
            // consuming the stranger window earlier would be a silent quota
            // loss despite no accepted message.
            if room.kind == "direct" {
                guard let strangerMessagePolicy else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await enforceDirectMessagePolicy(roomID: roomID, senderID: senderID, policy: strangerMessagePolicy, now: now, sql: sql)
            }

            try await persist(writeSet, command: command, room: room, sql: sql)
            let message = writeSet.acceptedMessage
            // The room row is locked for this transaction, so this metadata
            // is exactly the immutable mode that committed the event.  It is
            // used only to avoid emitting foreground-group hints for direct
            // rooms after the source transaction succeeds.
            return .accepted(.init(
                messageID: message.messageID,
                roomID: message.roomID,
                roomSequence: message.roomSequence,
                senderUserID: message.senderUserID,
                clientMessageID: message.clientMessageID,
                text: message.text,
                media: message.media,
                mentions: message.mentions,
                groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                createdAt: message.createdAt
            ))
        }
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

    private func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
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
                (message_id, room_id, room_sequence, sender_user_id, client_message_id, text_body, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: message.createdAt))
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
                    'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                    'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
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

    private func assertAvailableMedia(_ media: [V2MediaReference], ownerID: UUID, now: Date, sql: any SQLDatabase) async throws {
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        for reference in media {
            let mediaID = try uuid(reference.mediaID)
            guard try await sql.raw("SELECT media_id FROM im_v2.media_objects WHERE media_id = \(bind: mediaID) AND owner_user_id = \(bind: ownerID) AND state = 'available' AND expires_at > \(bind: now) FOR UPDATE").first(decoding: MediaReferenceRow.self) != nil else { throw V2MediaStoreError.mediaUnavailable }
        }
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
}

private extension V2SendMessageAcceptanceResult {
    var outcome: V2SendMessageOutcome {
        switch self {
        case .accepted(let transaction): .accepted(transaction.acceptedMessage)
        case .idempotent(let message): .idempotent(message)
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
        let accepted = V2AcceptedMessage(
            messageID: identifiers.messageID,
            roomID: command.roomID,
            roomSequence: roomState.nextRoomSequence,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID,
            text: command.text,
            media: command.media,
            mentions: command.mentions,
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
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case messageID = "message_id", roomID = "room_id", roomSequence = "room_sequence", senderUserID = "sender_user_id", clientMessageID = "client_message_id", textBody = "text_body", createdAt = "created_at" }
    func acceptedMessage(
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        groupDeliveryMode: V2GroupDeliveryMode? = nil
    ) throws -> V2AcceptedMessage {
        try .init(messageID: .init(messageID.uuidString), roomID: .init(roomID.uuidString), roomSequence: unsigned(roomSequence), senderUserID: .init(senderUserID.uuidString), clientMessageID: .init(clientMessageID.uuidString), text: textBody, media: media, mentions: mentions, groupDeliveryMode: groupDeliveryMode, createdAt: createdAt)
    }
}

private struct AuthorizationRow: Decodable { let authorized: Bool }
private struct MuteAuthorizationRow: Decodable { let muted: Bool }
private struct DirectRoomPairRow: Decodable {
    let lowerUserID: UUID
    let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct DirectPolicyBooleanRow: Decodable { let value: Bool }
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
private struct MediaReferenceRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct MentionSenderMembershipRow: Decodable { let role: String }
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
