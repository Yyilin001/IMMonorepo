import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core

/// 控制目录只解析已有身份。未知房间不会落入创建路径，
/// 也不会被分配给重新计算哈希所得的所有者。
public struct V2RoomServerOwnerResolver: V2RoomDataOwnerResolving {
    private let router: any V2RoomShardRouting

    public init(router: any V2RoomShardRouting) { self.router = router }

    public func owner(for roomID: RoomID) async throws -> V2RoomDataOwner {
        do {
            let route = try await router.route(for: roomID)
            return try .init(shardID: route.shardID, epoch: route.epoch)
        } catch V2RoomShardRouteError.roomNotFound {
            throw V2RoomActorStateError.roomNotFound
        }
    }
}
