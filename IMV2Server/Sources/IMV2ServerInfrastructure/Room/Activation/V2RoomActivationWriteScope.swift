import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 对一个已授权执行轮次，或同一物理所有者上有界的一组执行轮次，
/// 提供不可变权限。事务持有房间锁期间，此对象不解析房间，
/// 也不获取其他执行轮次。
public struct V2RoomActivationWriteScope: Sendable {
    let reliesOnRuntimeLifecycle: Bool
    private let byRoom: [UUID: V2RoomActivationToken]

    public init(tokens: [V2RoomActivationToken]) throws {
        try self.init(tokens: tokens, reliesOnRuntimeLifecycle: false)
    }

    init(tokens: [V2RoomActivationToken], reliesOnRuntimeLifecycle: Bool) throws {
        self.reliesOnRuntimeLifecycle = reliesOnRuntimeLifecycle
        guard !tokens.isEmpty, tokens.count <= 128,
              Set(tokens.map { $0.owner.shardID }).count == 1 else {
            throw V2RoomActorStateError.activationChanged
        }
        var entries: [UUID: V2RoomActivationToken] = [:]
        for token in tokens {
            guard let room = token.roomID.uuidValue,
                  entries.updateValue(token, forKey: room) == nil else {
                throw V2RoomActorStateError.activationChanged
            }
        }
        byRoom = entries
    }

    func token(for roomID: UUID) throws -> V2RoomActivationToken {
        guard let token = byRoom[roomID] else {
            throw V2RoomActorStateError.activationChanged
        }
        return token
    }

    func require(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        let tokens = try Set(roomIDs).map { try token(for: $0) }
        if !reliesOnRuntimeLifecycle { try await v2RequireRoomActivations(tokens: tokens, sql: sql) }
    }
}
