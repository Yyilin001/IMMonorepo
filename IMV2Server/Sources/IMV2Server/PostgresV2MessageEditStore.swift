import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Commits a revision-fenced text replacement, its authoritative room event,
/// fan-out plan and durable operation replay record as one transaction.
public struct PostgresV2MessageEditStore: V2MessageEditStore {
    private let database: any Database
    private let contentReviewMode: V2ContentReviewMode

    public init(database: any Database, contentReviewMode: V2ContentReviewMode) {
        self.database = database
        self.contentReviewMode = contentReviewMode
    }

    public func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageEditOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageEditStoreError.corruptPersistenceState }
            let roomID = try editUUID(command.roomID), actorID = try editUUID(command.actorUserID)
            let operationID = try editUUID(command.operationID), messageID = try editUUID(command.messageID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actorID.uuidString + ":" + operationID.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT room_id, message_id, expected_message_revision, text_body, resulting_message_revision, room_sequence, event_id, plan_id, created_at FROM im_v2.message_edit_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: EditOperationRow.self) {
                guard prior.matches(command, roomID: roomID, messageID: messageID) else { return .idempotencyConflict }
                return .idempotent(try prior.result())
            }
            guard let room = try await sql.raw("SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, delivery_mode FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: EditRoomRow.self) else { throw V2MessageEditStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2MessageEditStoreError.corruptPersistenceState }
            guard let message = try await sql.raw("SELECT room_id, sender_user_id, content_revision, withdrawn_at FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE").first(decoding: EditMessageRow.self), message.roomID == roomID else { throw V2MessageEditStoreError.messageNotFound }
            guard message.senderUserID == actorID else { throw V2MessageEditStoreError.actorNotAuthor }
            // A tombstone is terminal for content mutation. Check it before the
            // revision fence so an edit captured before a concurrent withdrawal
            // observes the durable terminal state rather than looking like a
            // potentially retryable stale-write conflict.
            guard message.withdrawnAt == nil else { return .alreadyWithdrawn }
            guard try editUnsigned(message.contentRevision) == command.expectedMessageRevision else { return .revisionConflict(current: try editUnsigned(message.contentRevision)) }
            guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: EditAdmissionRow.self), let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) FOR UPDATE").first(decoding: EditShardRow.self) else { throw V2MessageEditStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2MessageEditStoreError.corruptPersistenceState }
            let reservation = try V2RoomEventDeliveryMode.reserve(deliveryMode: room.deliveryMode, targetRule: .eligibleMemberCount, profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState, nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max, message.contentRevision < Int64.max else { throw V2MessageEditStoreError.corruptPersistenceState }
            let nextSequence = room.roomSequence + 1, nextRevision = message.contentRevision + 1
            let eventUUID = try editUUID(eventID), planUUID = try editUUID(planID)
            let previousProjectionState = try await PostgresV2MessageProjectionStateRepository()
                .loadCurrentOrMaterialize(
                    messageID: messageID,
                    revision: message.contentRevision,
                    sql: sql
                )
            let editedProjectionState = try previousProjectionState.state.applyingEdit(
                revision: editUnsigned(nextRevision),
                text: command.text,
                entities: []
            )
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence) WHERE room_id = \(bind: roomID)").run()
            try await sql.raw("UPDATE im_v2.messages SET text_body = \(bind: command.text), rich_entities = '[]'::jsonb, content_revision = \(bind: nextRevision) WHERE message_id = \(bind: messageID)").run()
            if contentReviewMode.enqueuesJobs {
                // A review verdict is valid only for the exact content revision.
                // Replacing a claimed job clears its lease in this same edit
                // transaction, so an old worker can only mark itself superseded.
                try await sql.raw("""
                    INSERT INTO im_v2.content_review_jobs
                        (message_id, room_id, expected_content_revision, state, decision, claim_token, lease_expires_at, retry_count, created_at, completed_at)
                    VALUES (\(bind: messageID), \(bind: roomID), \(bind: nextRevision), 'pending', NULL, NULL, NULL, 0, \(bind: now), NULL)
                    ON CONFLICT (message_id) DO UPDATE
                    SET expected_content_revision = EXCLUDED.expected_content_revision, state = 'pending', decision = NULL,
                        claim_token = NULL, lease_expires_at = NULL, retry_count = 0,
                        next_attempt_at = NULL, paused_at = NULL, finding_category = NULL,
                        finding_severity = NULL, finding_confidence = NULL, completed_at = NULL
                    """).run()
            }
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), fanout_window_used = \(bind: nextRoom.fanoutWindow.used), outstanding_fanout_units = \(bind: nextRoom.outstandingFanoutUnits), outstanding_plans = \(bind: nextRoom.outstandingPlans), shard_lease_id = \(bind: try editUUID(lease.id)), shard_lease_generation = \(bind: try editSigned(lease.generation)) WHERE room_id = \(bind: roomID)").run()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used), fanout_window_used = \(bind: lease.fanoutWindow.used), outstanding_fanout_units = \(bind: nextShard.outstandingFanoutUnits), outstanding_plans = \(bind: nextShard.outstandingPlans) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try editUUID(lease.id)) AND generation = \(bind: try editSigned(lease.generation))").run()
            try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), 'message.edited', \(bind: actorID), jsonb_build_object('event_type', 'message.edited', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: nextSequence), 'message_id', \(bind: messageID.uuidString), 'message_revision', \(bind: nextRevision), 'text', \(bind: command.text), 'entities', '[]'::jsonb, 'actor_user_id', \(bind: actorID.uuidString), 'server_created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: room.membershipRevision), \(bind: now))").run()
            try await PostgresV2MessageProjectionStateRepository().persist(
                try .init(
                    state: editedProjectionState,
                    originEventID: previousProjectionState.originEventID,
                    stateEventID: eventUUID,
                    createdAt: now
                ),
                sql: sql
            )
            try await V2RoomEventDeliveryMode.persistPlan(deliveryMode: room.deliveryMode, planID: planUUID, eventID: eventUUID, roomID: roomID, roomSequence: nextSequence, committedMembershipRevision: room.membershipRevision, standardTargetRuleJSON: "{\"kind\":\"eligible_member_count\"}", standardTargetCount: admission.eligibleMemberCount, now: now, sql: sql)
            try await sql.raw("INSERT INTO im_v2.message_edit_operations (actor_user_id, operation_id, room_id, message_id, expected_message_revision, text_body, resulting_message_revision, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: messageID), \(bind: try editSigned(command.expectedMessageRevision)), \(bind: command.text), \(bind: nextRevision), \(bind: nextSequence), \(bind: eventUUID), \(bind: planUUID), \(bind: now))").run()
            return .edited(try .init(roomID: command.roomID, messageID: command.messageID, text: command.text, messageRevision: editUnsigned(nextRevision), roomSequence: editUnsigned(nextSequence), eventID: eventID, fanoutPlanID: planID, createdAt: now))
        }
    }
}

private struct EditRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let deliveryMode: V2GroupDeliveryMode; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode" } }
private struct EditMessageRow: Decodable { let roomID: UUID; let senderUserID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct EditOperationRow: Decodable { let roomID: UUID; let messageID: UUID; let expectedMessageRevision: Int64; let text: String; let resultingMessageRevision: Int64; let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", expectedMessageRevision = "expected_message_revision", text = "text_body", resultingMessageRevision = "resulting_message_revision", roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }; func matches(_ command: V2EditMessageCommand, roomID: UUID, messageID: UUID) -> Bool { self.roomID == roomID && self.messageID == messageID && expectedMessageRevision == Int64(command.expectedMessageRevision) && text == command.text }; func result() throws -> V2MessageEdit { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), text: text, messageRevision: editUnsigned(resultingMessageRevision), roomSequence: editUnsigned(roomSequence), eventID: .init(eventID.uuidString), fanoutPlanID: .init(planID.uuidString), createdAt: createdAt) } }
private struct EditAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension EditAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct EditShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int }
extension EditShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: editUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private func editUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2MessageEditStoreError.corruptPersistenceState }; return value }
private func editUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2MessageEditStoreError.corruptPersistenceState }; return UInt64(value) }
private func editSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2MessageEditStoreError.corruptPersistenceState }; return Int64(value) }
