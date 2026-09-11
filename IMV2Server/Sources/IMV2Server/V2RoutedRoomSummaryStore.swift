import Foundation
import IMV2Core

/// 把会话摘要读取展开到全部房间分片。
///
/// 会话列表与单房间读取有一个根本差别：单房间请求已经知道房间标识，可以按归属路由；
/// 会话列表只知道**用户**，而成员关系存放在房间所属分片里。因此在分片部署下，"我的房间"
/// 不是一次查询，而是一次有界扇出：
///
/// - 每个**物理**存储最多查询一次（逻辑分片可能共用同一个库，见
///   `physicalStoreKeyByShard`），所以代价随物理存储数增长，不随房间数增长；
/// - 每个存储返回的都是它自己的前 `limit` 行，合并后取全局前 `limit` 行。全局前 N 行
///   必然包含在各存储的前 N 行里，因此页边界与单库实现完全一致；
/// - 只有在**所有**存储都取尽时页才算取尽，任何存储还有余量都说明全局还有余量。
///
/// 分片扩容只会增加扇出宽度，不会让单次请求退化成"扫描全部房间"。
public struct V2RoutedRoomSummaryStore: V2RoomSummaryStore {
    private let router: any V2RoomShardRouting
    /// 逻辑分片标识到物理存储键的映射。
    private let physicalStoreKeyByShard: [String: String]
    /// 每个物理存储一个代表，按物理键排序以保证扇出顺序稳定。
    private let representatives: [(key: String, store: any V2RoomSummaryStore)]

    /// 组合路由、各分片存储与物理键映射。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到摘要存储的映射。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 存储为空、标识为空白或物理键与逻辑标识不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2RoomSummaryStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        guard !stores.isEmpty,
              stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        let keys = physicalStoreKeyByShard ?? Dictionary(
            uniqueKeysWithValues: stores.keys.map { ($0, $0) }
        )
        guard Set(keys.keys) == Set(stores.keys),
              keys.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.physicalStoreKeyByShard = keys
        // 代表选择必须是确定的：同一个物理库可能被多个逻辑分片指向，选谁不影响
        // 结果，但随机选择会让日志、测试与故障排查无法复现。
        var shardsByPhysicalKey: [String: [String]] = [:]
        for shardID in keys.keys {
            guard let physicalKey = keys[shardID] else { continue }
            shardsByPhysicalKey[physicalKey, default: []].append(shardID)
        }
        representatives = shardsByPhysicalKey.keys.sorted().compactMap { physicalKey in
            guard let shardID = shardsByPhysicalKey[physicalKey]?.min(),
                  let store = stores[shardID]
            else { return nil }
            return (key: physicalKey, store: store)
        }
    }

    /// 读取一页房间活动水位。
    ///
    /// 各物理存储并行读取各自的前 `limit` 行，随后按 `(last_event_at, room_id)` 降序合并。
    ///
    /// - Parameters:
    ///   - cursor: 上一页游标；为空表示从最新活动开始。
    ///   - actorUserID: 发起查询的用户。
    ///   - limit: 本页最多返回的房间数。
    /// - Returns: 全局有界分页；`hasMore` 在所有存储都取尽时才为 `false`。
    /// - Throws: 条数越界时抛出 ``V2RoomSummaryError/invalidRequest``；其余错误来自分片存储。
    public func roomActivityWatermarks(
        after cursor: V2RoomSummaryCursor?,
        actorUserID: UserID,
        limit: Int
    ) async throws -> V2RoomActivityPage {
        guard limit > 0, limit <= V2RoomSummaryRequest.maximumPageSize else {
            throw V2RoomSummaryError.invalidRequest
        }
        let pages = try await withThrowingTaskGroup(of: (Int, V2RoomActivityPage).self) { group in
            for (index, representative) in representatives.enumerated() {
                group.addTask {
                    let page = try await representative.store.roomActivityWatermarks(
                        after: cursor,
                        actorUserID: actorUserID,
                        limit: limit
                    )
                    return (index, page)
                }
            }
            var collected: [(Int, V2RoomActivityPage)] = []
            collected.reserveCapacity(representatives.count)
            for try await page in group { collected.append(page) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var hasMore = false
        var seen: Set<RoomID> = []
        var merged: [V2RoomActivityWatermark] = []
        merged.reserveCapacity(limit + 1)
        for (_, page) in pages {
            hasMore = hasMore || page.hasMore
            for watermark in page.rooms where seen.insert(watermark.roomID).inserted {
                merged.append(watermark)
            }
        }
        // 逻辑分片可能共用物理存储；键映射保证每个物理存储只查一次，这里的去重只是
        // 防御性的最后一道闸门，不参与页边界计算。
        merged.sort {
            ($0.lastEventAtMicroseconds, $0.roomID) > ($1.lastEventAtMicroseconds, $1.roomID)
        }
        let rows = merged.count > limit ? Array(merged.prefix(limit)) : merged
        return V2RoomActivityPage(rooms: rows, hasMore: hasMore || merged.count > limit)
    }

    /// 读取指定房间对指定用户可见的最新消息摘要。
    ///
    /// 每个房间按归属路由到它所在的物理存储，然后按存储分组并行查询。
    ///
    /// - Parameters:
    ///   - roomIDs: 待查询房间；调用方必须传入有界集合。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 每个有可见消息的房间各一条摘要。
    /// - Throws: 条数为零、越界或房间归属未配置时抛出错误；其余错误来自分片存储。
    public func visibleMessages(roomIDs: [RoomID], actorUserID: UserID) async throws -> [V2RoomSummaryMessage] {
        guard !roomIDs.isEmpty, roomIDs.count <= V2RoomSummaryRequest.maximumPageSize else {
            throw V2RoomSummaryError.invalidRequest
        }
        let routes = try await router.routes(for: roomIDs)
        var roomsByStoreKey: [String: [RoomID]] = [:]
        for roomID in roomIDs {
            guard let route = routes[roomID],
                  let storeKey = physicalStoreKeyByShard[route.shardID]
            else { throw V2RoomShardStorageRegistryError.unknownShardID }
            roomsByStoreKey[storeKey, default: []].append(roomID)
        }
        let queryPlan = representatives.compactMap { representative -> (key: String, store: any V2RoomSummaryStore, rooms: [RoomID])? in
            guard let rooms = roomsByStoreKey[representative.key] else { return nil }
            return (key: representative.key, store: representative.store, rooms: rooms)
        }
        return try await withThrowingTaskGroup(of: (Int, [V2RoomSummaryMessage]).self) { group in
            for (index, plan) in queryPlan.enumerated() {
                group.addTask {
                    (index, try await plan.store.visibleMessages(roomIDs: plan.rooms, actorUserID: actorUserID))
                }
            }
            var collected: [(Int, [V2RoomSummaryMessage])] = []
            collected.reserveCapacity(queryPlan.count)
            for try await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}
