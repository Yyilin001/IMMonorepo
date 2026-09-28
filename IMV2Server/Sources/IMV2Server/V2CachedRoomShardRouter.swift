import Foundation
import IMV2Core
import Synchronization

/// 为持久化房间归属目录提供有界、进程内的路由提示缓存。
///
/// 只缓存分片与路由代次，不缓存授权或房间业务状态；命中仍需由归属存储验证命令。
/// 未命中调用底层目录。缓存按房间哈希分桶，以每桶互斥锁保护状态，不在持锁期间等待数据库。
/// 每桶独立限制容量，满时任意淘汰一项，不提供全局 LRU 或跨桶空闲容量借用。
///
/// 有效期使用单调时钟，命中不续期。过期项保留代次以抵御并发回源的旧结果，
/// 但仍可能被容量淘汰；该机制不替代归属存储的权威校验，也不合并并发回源请求。
public final class V2CachedRoomShardRouter: V2DirectRoomShardRouting, Sendable {
    /// 路由提示及其单调时钟过期时刻。
    private struct Entry: Sendable {
        let route: V2RoomShardRoute
        let expiresAt: ContinuousClock.Instant
    }

    /// 单桶房间条目映射，所有访问由桶的互斥锁保护。
    private struct BucketState: Sendable {
        var entries: [RoomID: Entry] = [:]
    }

    /// 具有独立容量预算和锁的缓存分区。
    private final class Bucket: Sendable {
        let capacity: Int
        let state = Mutex(BucketState())

        init(capacity: Int) { self.capacity = capacity }
    }

    private let source: any V2DirectRoomShardRouting
    private let buckets: [Bucket]
    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// 创建缓存包装器，不预分配房间条目，也不读取目录。
    ///
    /// - Parameters:
    ///   - source: 缓存未命中及私聊创建时使用的权威路由来源。
    ///   - capacity: 总条目预算，默认 250,000，小于一时按一处理。
    ///   - lifetime: 条目有效期，默认 300 秒，小于一秒时按一秒处理。
    ///   - bucketCount: 桶数量，默认 64，限制在一至规范化后的总容量之间。
    ///   - now: 可注入的单调时钟读取函数，默认读取当前连续时钟时刻。
    ///
    /// 总预算按商与余数精确分配到各桶，不因向上取整增加实际条目上限。
    public init(
        source: any V2DirectRoomShardRouting,
        capacity: Int = 250_000,
        lifetime: Duration = .seconds(300),
        bucketCount: Int = 64,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        let capacity = max(1, capacity)
        let count = min(max(1, bucketCount), capacity)
        let base = capacity / count
        let remainder = capacity % count
        self.source = source
        // 精确拆分配置预算，避免向上取整所需的加法溢出，
        // 或让每个桶额外分配条目。
        buckets = (0 ..< count).map { Bucket(capacity: base + ($0 < remainder ? 1 : 0)) }
        self.lifetime = max(.seconds(1), lifetime)
        self.now = now
    }

    /// 查询一个房间的缓存提示，失效或缺失时回源。
    ///
    /// - Parameter roomID: 已存在房间的标识。
    /// - Returns: 有效缓存或回源后的路由；若并发更新已保存更高代次，返回该更高代次。
    /// - Throws: 底层目录查询错误原样传播，不以过期项掩盖查询失败。
    ///
    /// 回源成功但结果代次较旧时，可能返回已过期的更高代次条目，同时保持其原截止时间。
    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        if let cached = cachedRoute(for: roomID) { return cached }
        let route = try await source.route(for: roomID)
        return insert(route, for: roomID)
    }

    /// 去重后批量解析房间，仅将未命中项交给底层批量接口。
    ///
    /// 底层结果须与未命中房间集合精确对应，否则在写入本批回源条目之前拒绝结果。
    /// 空输入直接返回空字典；方法不限制输入数组大小，调用方负责控制批量规模。
    ///
    /// - Parameter roomIDs: 待查询房间标识，可包含重复项。
    /// - Returns: 每个不同房间对应的路由，结果不承诺顺序；并发更新时保留较高代次。
    /// - Throws: 底层查询错误原样传播；返回集合不完整或标识不匹配时抛出
    ///   `V2RoomShardRouteError.roomNotFound`，不返回部分结果。
    public func routes(
        for roomIDs: [RoomID]
    ) async throws -> [RoomID: V2RoomShardRoute] {
        guard !roomIDs.isEmpty else { return [:] }
        let unique = Array(Set(roomIDs))
        var result: [RoomID: V2RoomShardRoute] = [:]
        var misses: [RoomID] = []
        result.reserveCapacity(unique.count)
        misses.reserveCapacity(unique.count)
        for roomID in unique {
            if let cached = cachedRoute(for: roomID) {
                result[roomID] = cached
            } else {
                misses.append(roomID)
            }
        }
        if !misses.isEmpty {
            let fetched = try await source.routes(for: misses)
            guard fetched.count == misses.count, misses.allSatisfy({ fetched[$0] != nil }) else {
                throw V2RoomShardRouteError.roomNotFound
            }
            for (roomID, route) in fetched {
                result[roomID] = insert(route, for: roomID)
            }
        }
        guard result.count == unique.count else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return result
    }

    /// 在底层私聊用户对路由保护范围内执行操作，待外层成功后再发布缓存提示。
    ///
    /// 回调成功不代表控制目录已经提交，只有底层整个调用成功且返回房间标识时才写缓存。
    /// 回调或目录提交失败均不通过此方法发布新条目；`nil` 房间标识表示无需缓存。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起私聊的用户。
    ///   - targetUserID: 私聊目标用户。
    ///   - proposedShardID: 提议的归属分片，由底层决定采用或复用既有路由。
    ///   - operation: 接收选定路由并执行创建或重放，返回业务结果和可选房间标识。
    /// - Returns: 回调产生的业务结果，不暴露缓存插入结果。
    /// - Throws: 底层路由过程或业务回调的错误原样传播。
    public func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        deadline: ContinuousClock.Instant? = nil,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (
            result: Result, roomID: RoomID?
        )
    ) async throws -> Result {
        let committed = try await source.withDirectPairRoute(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            proposedShardID: proposedShardID,
            deadline: deadline
        ) { route in
            let completion = try await operation(route)
            return (result: (value: completion.result, roomID: completion.roomID, route: route), roomID: completion.roomID)
        }
        // 控制目录失败前，所有者回调可能已成功。
        // 只有外围事务也提交后才发布路由。
        if let roomID = committed.roomID {
            insert(committed.route, for: roomID)
        }
        return committed.value
    }

    /// 返回严格晚于当前时刻过期的条目；过期项视为未命中，但保留其代次及容量占用。
    private func cachedRoute(for roomID: RoomID) -> V2RoomShardRoute? {
        let now = now()
        let bucket = bucket(for: roomID)
        return bucket.state.withLock { state in
            guard let entry = state.entries[roomID] else { return nil }
            guard entry.expiresAt > now else {
                // 刷新执行期间保留其纪元。该条目仍受相同的桶容量和淘汰规则约束。
                return nil
            }
            return entry.route
        }
    }

    /// 在单桶锁内写入路由与新截止时间，拒绝更低代次覆盖现存条目。
    ///
    /// 较旧结果直接返回现存路由，即使其已过期也不延长有效期；相同代次允许更新并续期。
    /// 新键遇到桶满时任意淘汰一项，既有键更新不额外占用容量。
    ///
    /// - Parameters:
    ///   - route: 回源或私聊创建返回的路由。
    ///   - roomID: 缓存键。
    /// - Returns: 本次保存的路由，或现存的更高代次路由。
    @discardableResult
    private func insert(_ route: V2RoomShardRoute, for roomID: RoomID) -> V2RoomShardRoute {
        let observedAt = now()
        let expiresAt = observedAt + lifetime
        let bucket = bucket(for: roomID)
        return bucket.state.withLock { state in
            // 目录读取可能乱序完成。较旧结果既不能替换较新的提示，
            // 也不能延长其过期时间，即使读取期间该提示已经过期。
            if let existing = state.entries[roomID], existing.route.epoch > route.epoch {
                return existing.route
            }
            if state.entries[roomID] == nil,
               state.entries.count >= bucket.capacity {
                // 路由 ID 均匀分布，且每个桶有界。
                // 任意替换可避免在高频查询路径上串行修改全局 LRU。
                state.entries.remove(at: state.entries.startIndex)
            }
            state.entries[roomID] = .init(
                route: route, expiresAt: expiresAt
            )
            return route
        }
    }

    /// 使用进程内哈希将房间映射到固定桶；该分桶不参与持久化分片选择。
    private func bucket(for roomID: RoomID) -> Bucket {
        var hasher = Hasher()
        hasher.combine(roomID)
        let hash = hasher.finalize()
        return buckets[Int(UInt(bitPattern: hash) % UInt(buckets.count))]
    }
}
