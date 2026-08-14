import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Serializes an actor's reaction operation, then commits the set change and
/// its room-derived propagation work as one transaction. Lock order follows
/// the other room mutations: operation → room → message → admission → shard.
public struct PostgresV2MessageReactionStore: V2MessageReactionStore {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageReactionOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let roomID = try reactionUUID(command.roomID), actorID = try reactionUUID(command.actorUserID)
            let operationID = try reactionUUID(command.operationID), messageID = try reactionUUID(command.messageID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let prior = try await sql.raw("SELECT room_id, message_id, reaction, action, room_sequence, event_id, plan_id, created_at FROM im_v2.message_reaction_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: ReactionOperationRow.self) {
                guard prior.matches(command, roomID: roomID, messageID: messageID) else { return .idempotencyConflict }
                return .idempotent(try prior.result(actorUserID: command.actorUserID))
            }
            guard let room = try await sql.raw("SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, delivery_mode FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReactionRoomRow.self) else { throw V2MessageReactionStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2MessageReactionStoreError.corruptPersistenceState }
            guard let message = try await sql.raw("SELECT room_id, withdrawn_at FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE").first(decoding: ReactionMessageRow.self), message.roomID == roomID else { throw V2MessageReactionStoreError.messageNotFound }
            guard message.withdrawnAt == nil else { throw V2MessageReactionStoreError.messageWithdrawn }
            let member = try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID) AND joined_revision <= \(bind: room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))").first(decoding: ReactionExistsRow.self)
            guard member != nil else { throw V2MessageReactionStoreError.actorNotMember }
            let exists = try await sql.raw("SELECT 1 AS exists FROM im_v2.message_reactions WHERE message_id = \(bind: messageID) AND actor_user_id = \(bind: actorID) AND reaction = \(bind: command.reaction) FOR UPDATE").first(decoding: ReactionExistsRow.self) != nil
            guard (command.action == .add && !exists) || (command.action == .remove && exists) else { return .alreadyInDesiredState }
            if command.action == .add {
                guard let counts = try await sql.raw("""
                    SELECT COUNT(*)::bigint AS total_count,
                           COUNT(*) FILTER (WHERE actor_user_id = \(bind: actorID))::bigint AS actor_count
                    FROM im_v2.message_reactions
                    WHERE message_id = \(bind: messageID)
                    """).first(decoding: ReactionCountRow.self) else {
                    throw V2MessageReactionStoreError.corruptPersistenceState
                }
                guard counts.totalCount < V2MessageReactionLimits.maximumReactionsPerMessage,
                      counts.actorCount < V2MessageReactionLimits.maximumReactionsPerActorPerMessage
                else { throw V2MessageReactionStoreError.reactionLimitReached }
            }

            guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReactionAdmissionRow.self),
                  let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) FOR UPDATE").first(decoding: ReactionShardRow.self) else { throw V2MessageReactionStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let reservation = try V2RoomEventDeliveryMode.reserve(deliveryMode: room.deliveryMode, targetRule: .eligibleMemberCount, profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState, nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let nextSequence = room.roomSequence + 1, eventUUID = try reactionUUID(eventID), planUUID = try reactionUUID(planID)
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence) WHERE room_id = \(bind: roomID)").run()
            if command.action == .add {
                try await sql.raw("INSERT INTO im_v2.message_reactions (message_id, actor_user_id, reaction, created_at) VALUES (\(bind: messageID), \(bind: actorID), \(bind: command.reaction), \(bind: now))").run()
            } else {
                try await sql.raw("DELETE FROM im_v2.message_reactions WHERE message_id = \(bind: messageID) AND actor_user_id = \(bind: actorID) AND reaction = \(bind: command.reaction)").run()
            }
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), fanout_window_used = \(bind: nextRoom.fanoutWindow.used), outstanding_fanout_units = \(bind: nextRoom.outstandingFanoutUnits), outstanding_plans = \(bind: nextRoom.outstandingPlans), shard_lease_id = \(bind: try reactionUUID(lease.id)), shard_lease_generation = \(bind: try reactionSigned(lease.generation)) WHERE room_id = \(bind: roomID)").run()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used), fanout_window_used = \(bind: lease.fanoutWindow.used), outstanding_fanout_units = \(bind: nextShard.outstandingFanoutUnits), outstanding_plans = \(bind: nextShard.outstandingPlans) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try reactionUUID(lease.id)) AND generation = \(bind: try reactionSigned(lease.generation))").run()
            try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), 'message.reaction_changed', \(bind: actorID), jsonb_build_object('event_type', 'message.reaction_changed', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: nextSequence), 'message_id', \(bind: messageID.uuidString), 'actor_user_id', \(bind: actorID.uuidString), 'reaction', \(bind: command.reaction), 'action', \(bind: command.action.rawValue), 'server_created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: room.membershipRevision), \(bind: now))").run()
            try await V2RoomEventDeliveryMode.persistPlan(deliveryMode: room.deliveryMode, planID: planUUID, eventID: eventUUID, roomID: roomID, roomSequence: nextSequence, committedMembershipRevision: room.membershipRevision, standardTargetRuleJSON: "{\"kind\":\"eligible_member_count\"}", standardTargetCount: admission.eligibleMemberCount, now: now, sql: sql)
            try await sql.raw("INSERT INTO im_v2.message_reaction_operations (actor_user_id, operation_id, room_id, message_id, reaction, action, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: messageID), \(bind: command.reaction), \(bind: command.action.rawValue), \(bind: nextSequence), \(bind: eventUUID), \(bind: planUUID), \(bind: now))").run()
            return .changed(try .init(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID, reaction: command.reaction, action: command.action, roomSequence: reactionUnsigned(nextSequence), eventID: eventID, fanoutPlanID: planID, createdAt: now))
        }
    }
}

private struct ReactionRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let deliveryMode: V2GroupDeliveryMode; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode" } }
private struct ReactionMessageRow: Decodable { let roomID: UUID; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", withdrawnAt = "withdrawn_at" } }
private struct ReactionExistsRow: Decodable { let exists: Int }
private struct ReactionCountRow: Decodable {
    let totalCount: Int
    let actorCount: Int
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case actorCount = "actor_count"
    }
}
private struct ReactionOperationRow: Decodable { let roomID: UUID; let messageID: UUID; let reaction: String; let action: String; let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", reaction, action, roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }; func matches(_ command: V2ChangeMessageReactionCommand, roomID: UUID, messageID: UUID) -> Bool { self.roomID == roomID && self.messageID == messageID && reaction == command.reaction && action == command.action.rawValue }; func result(actorUserID: UserID) throws -> V2MessageReactionChange { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), actorUserID: actorUserID, reaction: reaction, action: try reactionAction(action), roomSequence: reactionUnsigned(roomSequence), eventID: .init(eventID.uuidString), fanoutPlanID: .init(planID.uuidString), createdAt: createdAt) } }
private struct ReactionAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension ReactionAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct ReactionShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int }
extension ReactionShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: reactionUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private func reactionUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: identifier.rawValue) else { throw V2MessageReactionStoreError.corruptPersistenceState }; return value }
private func reactionUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2MessageReactionStoreError.corruptPersistenceState }; return UInt64(value) }
private func reactionSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2MessageReactionStoreError.corruptPersistenceState }; return Int64(value) }
private func reactionAction(_ rawValue: String) throws -> V2MessageReactionAction { guard let action = V2MessageReactionAction(rawValue: rawValue) else { throw V2MessageReactionStoreError.corruptPersistenceState }; return action }
