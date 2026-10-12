import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import SQLKit

/// Validate durable data-owner routes for an authorized read snapshot.
/// A stale room does not prevent a healthy read sibling.
func v2RoomSnapshotReadActivationFences(
    tokens: [V2RoomActivationToken], sql: any SQLDatabase,
    schema: String = "im_v2", timeouts: V2RoomActivationSQLTimeouts = .default
) async throws -> [RoomID: Result<Void, any Error>] {
    defer { V2RoomSQLContinuationObservation.current?.finishWithoutDispatch() }
    v2PreconditionSQLSchema(schema)
    guard !tokens.isEmpty, tokens.count <= 100 else { throw V2RoomActorStateError.activationChanged }
    var expected: [UUID: V2RoomActivationToken] = [:]
    for token in tokens {
        guard let room = token.roomID.uuidValue, expected[room] == nil else {
            throw V2RoomActorStateError.activationChanged
        }
        expected[room] = token
    }
    let ordered = expected.keys.sorted { $0.uuidString < $1.uuidString }
    let input = String(decoding: try JSONEncoder().encode(ordered.map(\.uuidString)), as: UTF8.self)
    try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
    let rooms = try await v2RoomSQLObservedAll(sql.raw("""
        SELECT room_id,room_shard_id,owner_epoch FROM \(unsafeRaw: schema).rooms
        WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb))
        ORDER BY room_id FOR SHARE
        """), decoding: DurableOwnerBatchRoomRow.self, source: .durableFenceRooms)
    guard Set(rooms.map(\.roomID)).count == rooms.count,
          rooms.allSatisfy({ expected[$0.roomID] != nil }) else {
        throw V2RoomActorStateError.activationChanged
    }
    let owners = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })
    var result: [RoomID: Result<Void, any Error>] = [:]
    for id in ordered {
        let token = expected[id]!
        do {
            guard let owner = owners[id] else { throw V2RoomActorStateError.roomNotFound }
            guard owner.shardID == token.owner.shardID, owner.epoch == token.owner.epoch else {
                throw V2RoomActorStateError.ownerChanged
            }
            result[token.roomID] = .success(())
        } catch { result[token.roomID] = .failure(error) }
    }
    return result
}


private struct DurableOwnerBatchRoomRow: Decodable {
    let roomID: UUID, shardID: String, epoch: Int64
    enum CodingKeys: String, CodingKey { case roomID="room_id",shardID="room_shard_id",epoch="owner_epoch" }
}
