import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

/// Observes authority and freezes the immutable owner gate once. Replay callers
/// retain the returned command; they never prepare another gate for that ID.
func freezeMessageModerationFixture(database: any Database, roomID: RoomID, actorUserID: UserID,
    operationID: ModerationOperationID, messageID: MessageID, reasonCode: V2ModerationReasonCode,
    now: Date, ownerRoute: V2RoomShardRoute? = nil) async throws -> V2MessageModerationCommand {
    guard let sql = database as? any SQLDatabase,
          let milliseconds = UInt64(exactly: try v2GatewayMilliseconds(now)),
          milliseconds > 0, milliseconds <= UInt64(Int64.max)-120_000 else {
        throw V2MessageModerationValidationError.invalidIntent
    }
    if let ownerRoute { try await v2RequireRoomOwner(roomID: roomID.uuidValue!, route: ownerRoute, sql: sql) }
    let route = try #require(try await sql.raw("SELECT room_shard_id AS shard, route_epoch AS epoch FROM im_v2.room_owner_routes WHERE room_id=\(bind: roomID.uuidValue!)").first(decoding: MessageModerationFixtureRoute.self))
    return try await withRoomActivation(database: database, roomID: roomID,
        shardID: ownerRoute?.shardID ?? route.shard, epoch: ownerRoute.map { Int64($0.epoch) } ?? route.epoch) { token in
        let store = PostgresV2MessageModerationOperationStore(database: database, clock: { now })
        let baseline = try await store.baseline(.init(roomID: roomID, actorUserID: actorUserID, messageID: messageID), token: token)
        let intent = try V2MessageModerationIntent(roomID: roomID, actorUserID: actorUserID,
            operationID: operationID, messageID: messageID, reasonCode: reasonCode,
            expectedMessageRevision: baseline.messageRevision, expectedMembershipRevision: baseline.membershipRevision,
            confirmedUntilMilliseconds: milliseconds+120_000)
        guard case .admitted(let gate) = try await store.admit(intent, token: token) else {
            throw V2MessageModerationValidationError.invalidAdmission
        }
        return try .init(intent: intent, admission: gate)
    }
}

func submitMessageModerationFixture(database: any Database, command: V2MessageModerationCommand,
    profile: V2CapacityProfile, eventID: EventID, now: Date,
    ownerRoute: V2RoomShardRoute? = nil) async throws -> V2MessageModerationRecoveryResult {
    guard let sql = database as? any SQLDatabase else { throw V2MessageModerationValidationError.invalidIntent }
    if let ownerRoute { try await v2RequireRoomOwner(roomID: command.intent.roomID.uuidValue!, route: ownerRoute, sql: sql) }
    let route = try #require(try await sql.raw("SELECT room_shard_id AS shard, route_epoch AS epoch FROM im_v2.room_owner_routes WHERE room_id=\(bind: command.intent.roomID.uuidValue!)").first(decoding: MessageModerationFixtureRoute.self))
    return try await withRoomActivation(database: database, roomID: command.intent.roomID,
        shardID: ownerRoute?.shardID ?? route.shard, epoch: ownerRoute.map { Int64($0.epoch) } ?? route.epoch) { token in
        try await PostgresV2MessageModerationOperationStore(database: database, clock: { now })
            .submit(command, token: token, capacityProfile: profile, eventID: eventID)
    }
}

private struct MessageModerationFixtureRoute: Decodable { let shard: String; let epoch: Int64 }
