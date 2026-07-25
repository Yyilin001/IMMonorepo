import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Persists a message tombstone and its delivery work atomically. The lock
/// order is operation advisory lock → room → message → room admission → shard
/// pool; an accepted withdrawal never leaves a partially visible tombstone.
public struct PostgresV2MessageWithdrawalStore: V2MessageWithdrawalStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            let roomID = try withdrawalUUID(command.roomID)
            let actorID = try withdrawalUUID(command.actorUserID)
            let operationID = try withdrawalUUID(command.operationID)
            let messageID = try withdrawalUUID(command.messageID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()

            if let prior = try await sql.raw("""
                SELECT room_id, message_id, expected_message_revision, resulting_message_revision,
                       room_sequence, event_id, plan_id, created_at
                FROM im_v2.message_withdrawal_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: WithdrawalOperationRow.self) {
                guard prior.matches(command: command, roomID: roomID, messageID: messageID) else { return .idempotencyConflict }
                return .idempotent(try prior.result())
            }

            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: WithdrawalRoomRow.self) else { throw V2MessageWithdrawalStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            guard let message = try await sql.raw("""
                SELECT room_id, sender_user_id, content_revision, withdrawn_at
                FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE
                """).first(decoding: WithdrawalMessageRow.self) else { throw V2MessageWithdrawalStoreError.messageNotFound }
            guard message.roomID == roomID else { throw V2MessageWithdrawalStoreError.messageNotFound }
            guard message.senderUserID == actorID else { throw V2MessageWithdrawalStoreError.actorNotAuthor }
            guard try withdrawalUnsigned(message.contentRevision) == command.expectedMessageRevision else {
                return .revisionConflict(current: try withdrawalUnsigned(message.contentRevision))
            }
            guard message.withdrawnAt == nil else { return .alreadyWithdrawn }

            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                       outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: WithdrawalAdmissionRow.self),
                  let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used,
                       fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                       outstanding_fanout_units, max_outstanding_plans, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: WithdrawalShardRow.self) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else {
                throw V2MessageWithdrawalStoreError.corruptPersistenceState
            }

            let reservation = try FanoutAdmissionEvaluator.reserve(
                request: .init(targetRule: .eligibleMemberCount),
                profile: capacityProfile.limits,
                roomState: try admission.state(),
                shardState: try shard.state(),
                now: now
            )
            let nextRoom: RoomAdmissionState
            let nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard):
                nextRoom = reservedRoom
                nextShard = reservedShard
            }
            guard let lease = nextShard.lease,
                  room.roomSequence < Int64.max,
                  message.contentRevision < Int64.max
            else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            let nextRoomSequence = room.roomSequence + 1
            let nextMessageRevision = message.contentRevision + 1
            let eventUUID = try withdrawalUUID(eventID)
            let planUUID = try withdrawalUUID(planID)

            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextRoomSequence) WHERE room_id = \(bind: roomID)").run()
            try await sql.raw("""
                UPDATE im_v2.messages
                SET content_revision = \(bind: nextMessageRevision), withdrawn_at = \(bind: now), withdrawn_by_user_id = \(bind: actorID)
                WHERE message_id = \(bind: messageID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission
                SET command_window_used = \(bind: nextRoom.commandWindow.used),
                    fanout_window_used = \(bind: nextRoom.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: nextRoom.outstandingFanoutUnits),
                    outstanding_plans = \(bind: nextRoom.outstandingPlans),
                    shard_lease_id = \(bind: try withdrawalUUID(lease.id)), shard_lease_generation = \(bind: try withdrawalSigned(lease.generation))
                WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_used = \(bind: lease.commandWindow.used), fanout_window_used = \(bind: lease.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: nextShard.outstandingFanoutUnits), outstanding_plans = \(bind: nextShard.outstandingPlans)
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                  AND lease_id = \(bind: try withdrawalUUID(lease.id)) AND generation = \(bind: try withdrawalSigned(lease.generation))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextRoomSequence), 'message.withdrawn', \(bind: actorID),
                        jsonb_build_object('event_type', 'message.withdrawn', 'room_id', \(bind: roomID.uuidString),
                                           'room_sequence', \(bind: nextRoomSequence), 'message_id', \(bind: messageID.uuidString),
                                           'message_revision', \(bind: nextMessageRevision), 'actor_user_id', \(bind: actorID.uuidString),
                                           'server_created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000)),
                                           'is_withdrawn', true), \(bind: room.membershipRevision), \(bind: now))
                """).run()
            let targetCount = admission.eligibleMemberCount
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES (\(bind: planUUID), \(bind: eventUUID), \(bind: roomID), \(bind: nextRoomSequence), \(bind: room.membershipRevision),
                        '{"kind":"eligible_member_count"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                        \(bind: targetCount), \(bind: targetCount), 'planning', \(bind: now))
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at) VALUES (\(bind: eventUUID), \(bind: planUUID), 'pending', \(bind: now))").run()
            try await sql.raw("""
                INSERT INTO im_v2.message_withdrawal_operations
                    (actor_user_id, operation_id, room_id, message_id, expected_message_revision,
                     resulting_message_revision, room_sequence, event_id, plan_id, created_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: messageID), \(bind: try withdrawalSigned(command.expectedMessageRevision)),
                        \(bind: nextMessageRevision), \(bind: nextRoomSequence), \(bind: eventUUID), \(bind: planUUID), \(bind: now))
                """).run()
            return .withdrawn(try .init(roomID: command.roomID, messageID: command.messageID,
                                        messageRevision: withdrawalUnsigned(nextMessageRevision), roomSequence: withdrawalUnsigned(nextRoomSequence),
                                        eventID: eventID, fanoutPlanID: planID, createdAt: now))
        }
    }
}

private struct WithdrawalRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id" } }
private struct WithdrawalMessageRow: Decodable { let roomID: UUID; let senderUserID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct WithdrawalOperationRow: Decodable {
    let roomID: UUID; let messageID: UUID; let expectedMessageRevision: Int64; let resultingMessageRevision: Int64; let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", expectedMessageRevision = "expected_message_revision", resultingMessageRevision = "resulting_message_revision", roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }
    func matches(command: V2WithdrawMessageCommand, roomID: UUID, messageID: UUID) -> Bool { self.roomID == roomID && self.messageID == messageID && expectedMessageRevision == Int64(command.expectedMessageRevision) }
    func result() throws -> V2MessageWithdrawal { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), messageRevision: withdrawalUnsigned(resultingMessageRevision), roomSequence: withdrawalUnsigned(roomSequence), eventID: .init(eventID.uuidString), fanoutPlanID: .init(planID.uuidString), createdAt: createdAt) }
}
private struct WithdrawalAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension WithdrawalAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct WithdrawalShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int }
extension WithdrawalShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: withdrawalUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private func withdrawalUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: identifier.rawValue) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return value }
private func withdrawalUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return UInt64(value) }
private func withdrawalSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return Int64(value) }
