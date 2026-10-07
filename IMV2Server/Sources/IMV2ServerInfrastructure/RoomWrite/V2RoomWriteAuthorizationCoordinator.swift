import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Coordinates control-side intents and owner proofs without holding the owner's
/// acceptance transaction across the control-side reservation or acknowledgement.
struct V2RoomWriteAuthorizationCoordinator: Sendable {
    let database: any Database
    let controlDatabase: (any Database)?
    let resolutionDatabase: (any Database)?

    struct Prepared: Sendable {
        let roomKinds: [UUID: String]
        let grants: [V2DirectAuthorizationGrant]
    }

    func prepare(commands: [V2SendMessageCommand], now: Date, sendOperationMetrics: V2SendOperationBatchMetrics? = nil, preloadedRoutes: [DurableAuthorizationRouteRow]? = nil) async throws -> Prepared {
        guard !commands.isEmpty, commands.count <= 128 else { throw V2DirectAuthorizationIntentError.invalidRequest }
        let routeTimer = sendOperationMetrics?.startStage(.authorizationRoute)
        defer { routeTimer?.finish() }
        let keys = try Set(commands.map { V2DirectSendPolicyCache.Key(roomID: try uuid($0.roomID), senderID: try uuid($0.senderUserID)) })
        let input = try roomWriteJSON(keys.map { ["room_id": $0.roomID.uuidString, "sender_id": $0.senderID.uuidString] })
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let rows: [DurableAuthorizationRouteRow]
        if let preloadedRoutes {
            rows = preloadedRoutes.filter { keys.contains(.init(roomID: $0.roomID, senderID: $0.senderID)) }
        } else {
            rows = try await sql.raw("""
                SELECT input.room_id, input.sender_id, room.room_kind, room.room_shard_id, room.owner_epoch,
                    CASE WHEN pair.lower_user_id = input.sender_id THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_id
                FROM jsonb_to_recordset(\(bind: input)::jsonb) AS input(room_id uuid, sender_id uuid)
                JOIN im_v2.rooms room ON room.room_id = input.room_id
                LEFT JOIN im_v2.direct_room_pairs pair ON pair.room_id = input.room_id AND room.room_kind = 'direct'
                    AND input.sender_id IN (pair.lower_user_id, pair.higher_user_id)
                """).all(decoding: DurableAuthorizationRouteRow.self)
        }
        guard rows.count == keys.count else { throw V2RoomWriteStoreError.roomNotFound }
        let routes = Dictionary(uniqueKeysWithValues: rows.map { (V2DirectSendPolicyCache.Key(roomID: $0.roomID, senderID: $0.senderID), $0) })
        let roomKinds = Dictionary(rows.map { ($0.roomID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let requests: [V2DirectAuthorizationRequest] = try commands.compactMap { command in
            let room = try uuid(command.roomID), sender = try uuid(command.senderUserID)
            guard let row = routes[.init(roomID: room, senderID: sender)] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
            if row.kind == "group" { return nil }
            guard row.kind == "direct", let recipient = row.recipientID, command.fingerprint.version == 3 else {
                throw V2RoomWriteStoreError.actorNotEligible
            }
            return .init(roomID: room, senderID: sender, clientMessageID: try uuid(command.clientMessageID),
                recipientID: recipient, ownerShardID: row.shardID, ownerEpoch: row.epoch, fingerprint: command.fingerprint.digest)
        }
        if requests.isEmpty { return .init(roomKinds: roomKinds, grants: []) }
        routeTimer?.finish()
        let controlTimer = sendOperationMetrics?.startStage(.authorizationControl)
        defer { controlTimer?.finish() }
        guard let controlDatabase else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
        let grants = try await PostgresV2DirectAuthorizationIntentStore(database: controlDatabase).reserve(requests, now: now)
        return .init(roomKinds: roomKinds, grants: grants)
    }

    func acknowledge(_ grants: [V2DirectAuthorizationGrant], now: Date) async throws {
        guard let acknowledgement = resolutionDatabase else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
        let intents = PostgresV2DirectAuthorizationIntentStore(database: acknowledgement)
        do {
            for grant in grants {
                if let receipt = try await PostgresV2DirectAuthorizationReceiptStore().committedReceipt(grant.attempt, database: database) {
                    _ = try await intents.resolve(grant.attempt, receipt: receipt, now: now)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 此操作可能已提交。保留持久义务并映射为可重试协议错误，
            // 不得将 ACK 或数据库失败归类为新的命令身份冲突。
            throw V2DirectAuthorizationCoordinationError.ownerUnavailable
        }
    }


}

private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

struct DurableAuthorizationRouteRow: Decodable, Sendable {
    let roomID: UUID; let senderID: UUID; let recipientID: UUID?
    let kind: String; let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", senderID = "sender_id", recipientID = "recipient_id"
        case kind = "room_kind", shardID = "room_shard_id", epoch = "owner_epoch"
    }
}
