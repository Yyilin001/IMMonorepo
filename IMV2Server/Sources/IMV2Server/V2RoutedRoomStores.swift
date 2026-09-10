import Foundation
import IMV2Core

/// 把既有房间写入路由到控制面记录的物理归属。
///
/// 选中的存储在失败后绝不会改试第二个归属：重试与幂等仍由调用方负责，
/// 房间始终只对应一个串行写入者。
public struct V2RoutedRoomWriteStore: V2AtomicRoomWriteBatchStore {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2OwnerValidatedRoomWriteStore]
    /// 逻辑归属标识到物理存储键的映射。
    ///
    /// 分阶段发布期间多个逻辑归属可能共用同一物理库：这些标识上的命令可以保留
    /// 单次原子追加事务，而不同物理键的命令永远不会跨库执行。
    private let physicalStoreKeyByShard: [String: String]

    /// 组合路由来源、各归属存储与物理键映射。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到归属写存储的映射。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 归属存储为空、含空白标识，或物理键与逻辑标识不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2OwnerValidatedRoomWriteStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        guard !stores.isEmpty, stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        let keys = physicalStoreKeyByShard ?? Dictionary(
            uniqueKeysWithValues: stores.keys.map { ($0, $0) }
        )
        guard Set(keys.keys) == Set(stores.keys),
              keys.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.stores = stores
        self.physicalStoreKeyByShard = keys
    }

    /// 按房间归属接受一条写入。
    ///
    /// - Parameter request: 目标房间的写入请求。
    /// - Returns: 发送结果。
    /// - Throws: 归属未配置时抛出
    ///   ``V2RoomShardStorageRegistryError/unknownShardID``；其余错误来自归属存储。
    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        let route = try await router.route(for: command.roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return try await store.acceptOwnerValidated(
            request: .init(command: command, capacityProfile: capacityProfile,
                identifiers: identifiers, now: now), ownerRoute: route
        )
    }

    public func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        guard !requests.isEmpty else { return [] }
        do {
            let groups = try await groupedRequests(requests)
            return await withTaskGroup(
                of: [(Int, Bool)].self,
                returning: [Bool].self
            ) { group in
                for (_, entries) in groups {
                    guard let first = entries.first,
                          let store = stores[first.route.shardID]
                    else { return Array(repeating: false, count: requests.count) }
                    group.addTask {
                        let eligibility = await store.atomicBatchEligibility(
                            requests: entries.map(\.request)
                        )
                        guard eligibility.count == entries.count else {
                            return entries.map { ($0.index, false) }
                        }
                        return zip(entries, eligibility).map { ($0.0.index, $0.1) }
                    }
                }
                var result = Array(repeating: false, count: requests.count)
                for await entries in group {
                    for (index, eligible) in entries { result[index] = eligible }
                }
                return result
            }
        } catch {
            // This classifier must not turn a route failure into a client
            // acknowledgement. The ordinary path will surface the same
            // durable error through its established retry boundary.
            return Array(repeating: false, count: requests.count)
        }
    }

    public func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        guard !requests.isEmpty else { return [] }
        do {
            let groups = try await groupedRequests(requests)
            return await withTaskGroup(
                of: [(Int, V2AtomicRoomWriteBatchPartition?)].self,
                returning: [V2AtomicRoomWriteBatchPartition?].self
            ) { group in
                for (_, entries) in groups {
                    guard let first = entries.first,
                          let store = stores[first.route.shardID]
                    else { return Array(repeating: nil, count: requests.count) }
                    group.addTask {
                        let partitions = await store.atomicBatchPartitions(
                            requests: entries.map(\.request)
                        )
                        guard partitions.count == entries.count else {
                            return entries.map { ($0.index, nil) }
                        }
                        return zip(entries, partitions).map { ($0.0.index, $0.1) }
                    }
                }
                var result = Array<V2AtomicRoomWriteBatchPartition?>(
                    repeating: nil, count: requests.count
                )
                for await entries in group {
                    for (index, partition) in entries { result[index] = partition }
                }
                return result
            }
        } catch {
            return Array(repeating: nil, count: requests.count)
        }
    }

    public func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard !requests.isEmpty else { return [] }
        let groups = try await groupedRequests(requests)

        // Inputs in different owners are independent. Run those bounded
        // owner transactions concurrently, while each owner's PostgreSQL CTE
        // continues to serialize and order its own rooms.
        return try await withThrowingTaskGroup(
            of: [(Int, V2SendMessageOutcome)].self,
            returning: [V2SendMessageOutcome].self
        ) { group in
            for (_, entries) in groups {
                guard let first = entries.first,
                      let store = stores[first.route.shardID]
                else {
                    throw V2RoomShardStorageRegistryError.unknownShardID
                }
                group.addTask {
                    let shardRequests = entries.map(\.request)
                    let outcomes: [V2SendMessageOutcome]
                    if shardRequests.count == 1 {
                        let request = shardRequests[0]
                        outcomes = [try await store.acceptOwnerValidated(
                            request: request, ownerRoute: first.route
                        )]
                    } else {
                        outcomes = try await store.acceptAtomicallyOwnerValidated(
                            requests: entries.map { .init(request: $0.request, ownerRoute: $0.route) }
                        )
                    }
                    guard outcomes.count == entries.count else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    return zip(entries, outcomes).map { ($0.0.index, $0.1) }
                }
            }
            var ordered = Array<V2SendMessageOutcome?>(repeating: nil, count: requests.count)
            for try await outcomes in group {
                for (index, outcome) in outcomes { ordered[index] = outcome }
            }
            guard ordered.allSatisfy({ $0 != nil }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return ordered.map { $0! }
        }
    }

    private func groupedRequests(
        _ requests: [V2RoomWriteRequest]
    ) async throws -> [String: [(index: Int, request: V2RoomWriteRequest, route: V2RoomShardRoute)]] {
        let routes = try await router.routes(for: requests.map { $0.command.roomID })
        var groups: [String: [(index: Int, request: V2RoomWriteRequest, route: V2RoomShardRoute)]] = [:]
        for (index, request) in requests.enumerated() {
            guard let route = routes[request.command.roomID],
                  stores[route.shardID] != nil,
                  let physicalKey = physicalStoreKeyByShard[route.shardID]
            else { throw V2RoomShardStorageRegistryError.unknownShardID }
            groups[physicalKey, default: []].append((index, request, route))
        }
        return groups
    }
}

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

/// 房间日志读取路由存储。
///
/// 读取与写入使用同一套归属目录；缓存条目在返回之前仍会由被委托的存储
/// 依据该归属的持久化房间成员状态再次校验。
public struct V2RoutedGroupEventLogStore: V2GroupEventLogStore {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2GroupEventLogStore]

    /// 组合路由来源、各归属读取存储与可选的私聊日志缓存。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到归属读取存储的映射。
    ///   - directRoomLogEventCache: 私聊日志加速缓存，可选。
    /// - Throws: 归属存储为空或含空白标识时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2GroupEventLogStore]
    ) throws {
        guard !stores.isEmpty else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.stores = stores
    }

    /// 拉取一页房间事件。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页条数。
    /// - Returns: 事件分页。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func pull(
        roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int
    ) async throws -> V2GroupEventLogPage {
        try await store(for: roomID).pull(
            roomID: roomID, actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence, pageSize: pageSize
        )
    }

    /// 校验订阅资格并返回当前水位。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起订阅的用户。
    /// - Returns: 订阅结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func subscribe(
        roomID: RoomID, actorUserID: UserID
    ) async throws -> V2GroupEventSubscription {
        try await store(for: roomID).subscribe(roomID: roomID, actorUserID: actorUserID)
    }

    private func store(for roomID: RoomID) async throws -> any V2GroupEventLogStore {
        let route = try await router.route(for: roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return store
    }
}
