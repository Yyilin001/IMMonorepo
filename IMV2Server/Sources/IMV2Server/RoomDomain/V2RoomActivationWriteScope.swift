import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Immutable authority for one already granted turn, or a bounded collection of
/// granted turns on the same physical owner. This never resolves a room or
/// acquires another turn while a transaction holds room locks.
public struct V2RoomActivationWriteScope: Sendable {
    private let byRoom: [UUID: V2RoomActivationToken]

    public init(tokens: [V2RoomActivationToken]) throws {
        guard !tokens.isEmpty, tokens.count <= 128,
              Set(tokens.map { $0.owner.shardID }).count == 1 else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        var entries: [UUID: V2RoomActivationToken] = [:]
        for token in tokens {
            guard let room = token.roomID.uuidValue,
                  entries.updateValue(token, forKey: room) == nil else {
                throw V2RoomActivationLeaseError.activationChanged
            }
        }
        byRoom = entries
    }

    func token(for roomID: UUID) throws -> V2RoomActivationToken {
        guard let token = byRoom[roomID] else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        return token
    }

    func require(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        let tokens = try Set(roomIDs).map { try token(for: $0) }
        try await v2RequireRoomActivations(tokens: tokens, sql: sql)
    }
}
