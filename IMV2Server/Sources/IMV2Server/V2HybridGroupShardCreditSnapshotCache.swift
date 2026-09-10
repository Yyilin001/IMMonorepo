import Foundation
import IMV2Core

/// 混合大群命令额度使用的有界、短时存在的分片租约提示缓存。
///
/// 该缓存不是授权或容量权威：命中只能用于向 `V2ShardAdmissionCommandCreditPool`
/// 申请预留一批持久化命令额度。外层消息事务仍会比较房间归属与租约代次，
/// 并锁定接受流程用到的全部成员、权限与禁言行。
actor V2HybridGroupShardCreditSnapshotCache {
    /// 单个房间的租约提示。
    struct Entry: Sendable {
        let roomShardID: String
        let capacityProfileID: String
        let kind: String
        let deliveryMode: V2GroupDeliveryMode
        let frozenAt: Date?
        let roomShardLeaseID: UUID
        let roomShardLeaseGeneration: Int64
        let shardState: ShardAdmissionState
    }

    /// 一次批量更新中的房间与提示。
    struct Update: Sendable {
        /// 目标房间。
        let roomID: UUID
        /// 该房间的租约提示。
        let entry: Entry
    }

    /// 最近最少使用链表的节点。
    private final class Node {
        let roomID: UUID
        var entry: Entry
        var expiresAt: ContinuousClock.Instant
        weak var previous: Node?
        var next: Node?

        /// 以房间、提示与过期时刻构造节点。
        ///
        /// - Parameters:
        ///   - roomID: 房间标识。
        ///   - entry: 租约提示。
        ///   - expiresAt: 单调时钟过期时刻。
        init(roomID: UUID, entry: Entry, expiresAt: ContinuousClock.Instant) {
            self.roomID = roomID
            self.entry = entry
            self.expiresAt = expiresAt
        }
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [UUID: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?

    /// 创建容量与有效期有界的缓存。
    ///
    /// - Parameters:
    ///   - capacity: 条目容量上限，小于一时按一处理。
    ///   - lifetime: 条目有效期，小于一秒时按一秒处理。
    init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    /// 批量查询房间的租约提示。
    ///
    /// 过期条目会在查询时被移除并返回 `nil`；有效命中会被提升为最近使用。
    ///
    /// - Parameter roomIDs: 待查询的房间标识。
    /// - Returns: 与输入顺序一一对应的提示；缺失或已过期时为 `nil`。
    func values(for roomIDs: [UUID]) -> [Entry?] {
        let now = clock.now
        return roomIDs.map { roomID in
            guard let node = entries[roomID] else { return nil }
            guard node.expiresAt > now else {
                remove(node)
                return nil
            }
            moveToMostRecent(node)
            return node.entry
        }
    }

    /// 写入或刷新房间的租约提示。
    ///
    /// 已存在的条目会更新内容并重新计时；新条目在容量已满时淘汰最久未使用的一项。
    ///
    /// - Parameter updates: 待写入的房间与提示列表。
    func insert(_ updates: [Update]) {
        let now = clock.now
        for update in updates {
            if let node = entries[update.roomID] {
                node.entry = update.entry
                node.expiresAt = now + lifetime
                moveToMostRecent(node)
                continue
            }
            if entries.count >= capacity, let leastRecent {
                remove(leastRecent)
            }
            let node = Node(
                roomID: update.roomID,
                entry: update.entry,
                expiresAt: now + lifetime
            )
            entries[update.roomID] = node
            attachAsMostRecent(node)
        }
    }

    /// 移除指定房间的租约提示。
    ///
    /// 重复的房间标识会被先去重，不存在的条目会被忽略。
    ///
    /// - Parameter roomIDs: 需要失效的房间标识列表。
    func invalidate(_ roomIDs: [UUID]) {
        for roomID in Set(roomIDs) {
            if let node = entries[roomID] { remove(node) }
        }
    }

    /// 把节点提升为最近使用。
    ///
    /// - Parameter node: 目标节点。
    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        detach(node)
        attachAsMostRecent(node)
    }

    /// 把节点挂到最近使用端。
    ///
    /// - Parameter node: 目标节点。
    private func attachAsMostRecent(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    /// 把节点从链表中断开，不改变索引。
    ///
    /// - Parameter node: 目标节点。
    private func detach(_ node: Node) {
        if let previous = node.previous {
            previous.next = node.next
        } else {
            mostRecent = node.next
        }
        if let next = node.next {
            next.previous = node.previous
        } else {
            leastRecent = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    /// 断开节点并从索引中移除。
    ///
    /// - Parameter node: 目标节点。
    private func remove(_ node: Node) {
        detach(node)
        entries.removeValue(forKey: node.roomID)
    }
}
