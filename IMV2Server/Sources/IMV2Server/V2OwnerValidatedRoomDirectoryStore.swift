import IMV2Core

/// 过滤不属于此物理存储当前所有权范围的条目，同时保持扫描位置不变。
/// 外层目录服务还必须按拓扑代次对扫描设置栅栏。
public struct V2OwnerValidatedRoomDirectoryStore: V2UserRoomDirectoryReading {
    private let underlying: any V2UserRoomDirectoryReading
    private let router: any V2RoomShardRouting
    private let physicalStoreShardIDs: Set<String>

    public init(underlying: any V2UserRoomDirectoryReading,
                router: any V2RoomShardRouting, physicalStoreShardIDs: Set<String>) throws {
        guard !physicalStoreShardIDs.isEmpty,
              physicalStoreShardIDs.allSatisfy({ !$0.isEmpty }) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.underlying = underlying
        self.router = router
        self.physicalStoreShardIDs = physicalStoreShardIDs
    }

    public func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        guard limit > 0, limit <= 100 else { throw V2RoomRecoveryReadError.invalidRequest }
        try Task.checkCancellation()
        let slice = try await underlying.rooms(actorUserID: actorUserID, after: after, limit: limit)
        guard slice.entries.count <= limit,
              Set(slice.entries.map(\.roomID)).count == slice.entries.count else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        guard !slice.entries.isEmpty else { return slice }
        let routes = try await router.routes(for: slice.entries.map(\.roomID))
        try Task.checkCancellation()
        var entries: [V2UserRoomDirectoryEntry] = []
        for entry in slice.entries {
            // 路由缺失或不一致时，必须使整页失败；
            // 不能越过未经核实的成员，假装它已完成检查。
            guard let route = routes[entry.roomID] else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            guard physicalStoreShardIDs.contains(route.shardID) else { continue }
            guard UInt64(route.epoch) == entry.ownerEpoch else {
                throw V2RoomRecoveryReadError.topologyChanged
            }
            entries.append(entry)
        }
        return .init(entries: entries, scannedThrough: slice.scannedThrough, hasMore: slice.hasMore)
    }
}
