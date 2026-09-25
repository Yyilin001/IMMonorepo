import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit

/// 私聊房间创建路由存储。
///
/// 创建时尚不存在房间标识，因此它借助控制面目录的用户对栅栏选定一次归属，
/// 成功后把该决定持久化，而普通偏好写入仍交给控制面存储。
public struct V2RoutedDirectMessagingStore: V2DirectMessagingStore {
    private let router: any V2DirectRoomShardRouting
    private let ownerStores: [String: any V2DirectMessagingStore]
    private let controlStore: any V2DirectMessagingStore

    /// 组合路由来源、各归属存储与控制面存储。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到归属写存储的映射。
    ///   - controlStore: 处理偏好写入的控制面存储。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 归属存储为空、含空白标识，或物理键与逻辑标识不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2DirectRoomShardRouting,
        ownerStores: [String: any V2DirectMessagingStore],
        controlStore: any V2DirectMessagingStore
    ) throws {
        guard !ownerStores.isEmpty else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.ownerStores = ownerStores
        self.controlStore = controlStore
    }

    /// 打开或复用一对用户的私聊房间。
    ///
    /// - Parameters:
    ///   - command: 打开私聊房间命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 打开结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func open(
        command: V2OpenDirectRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        now: Date
    ) async throws -> V2OpenDirectRoomOutcome {
        try await router.withDirectPairRoute(
            actorUserID: command.actorUserID,
            targetUserID: command.targetUserID,
            proposedShardID: roomShardID
        ) { route in
            guard let store = ownerStores[route.shardID] else {
                throw V2RoomShardStorageRegistryError.unknownShardID
            }
            let outcome = try await store.open(
                command: command, capacityProfile: capacityProfile,
                roomShardID: route.shardID, roomID: roomID, now: now
            )
            let persistedRoomID: RoomID?
            switch outcome {
            case .opened(let room), .idempotent(let room): persistedRoomID = room.roomID
            case .idempotencyConflict, .unavailable: persistedRoomID = nil
            }
            return (outcome, persistedRoomID)
        }
    }

    /// 设置陌生人消息权限。
    ///
    /// 偏好属于用户维度，因此直接交给控制面存储。
    ///
    /// - Parameters:
    ///   - command: 权限变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 控制面存储抛出的错误。
    public func setStrangerMessagePermission(
        command: V2SetStrangerMessagePermissionCommand, now: Date
    ) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await controlStore.setStrangerMessagePermission(command: command, now: now)
    }

    /// 设置被添加好友权限。
    ///
    /// 偏好属于用户维度，因此直接交给控制面存储。
    ///
    /// - Parameters:
    ///   - command: 权限变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 控制面存储抛出的错误。
    public func setUserAddPermission(
        command: V2SetUserAddPermissionCommand, now: Date
    ) async throws -> V2SetUserAddPermissionOutcome {
        try await controlStore.setUserAddPermission(command: command, now: now)
    }
}
