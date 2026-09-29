import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 普通私聊房间日志追加快速路径使用的短时进程内快照。
///
/// 该缓存刻意不承担授权或排序权威：每次被接受的追加仍会在持有相应 PostgreSQL 锁的情况下
/// 比对已存房间序号、成员修订、私聊对修订以及双方的用户策略修订。
/// 因此过期条目只会导致快速路径内部未命中，随后走既有的完整接受路径重试。
public actor V2DirectRoomLogFastAppendCache {
    struct Update: Sendable {
        let entry: Entry
        let key: Key
    }

    public struct Key: Hashable, Sendable {
        public let roomID: UUID
        public let senderID: UUID

        public init(roomID: UUID, senderID: UUID) {
            self.roomID = roomID
            self.senderID = senderID
        }
    }

    /// 构造条件追加尝试所需的、按修订不可变的策略快照。
    ///
    /// 房间游标刻意不进入该条目：任何其他生产者都可能随时推进私聊房间，
    /// 而 PostgreSQL 可以在房间行锁下安全分配下一个序号。
    /// 若把这种高频变化的游标与稳定策略耦合，只要对端发送过消息，合法的授权缓存就会失效。
    public struct Entry: Sendable, Equatable {
        public let policy: V2DirectSendPolicyCache.Entry
        public let roomShardID: String
        public let capacityProfileID: String
        public let membershipRevision: Int64
        public let shardState: ShardAdmissionState

        public init(
            policy: V2DirectSendPolicyCache.Entry,
            roomShardID: String,
            capacityProfileID: String,
            membershipRevision: Int64,
            shardState: ShardAdmissionState
        ) {
            self.policy = policy
            self.roomShardID = roomShardID
            self.capacityProfileID = capacityProfileID
            self.membershipRevision = membershipRevision
            self.shardState = shardState
        }
    }

    /// Actor 隔离的侵入式最近最少使用节点。
    ///
    /// 容量淘汰必须保持 O(1)：该缓存在每次已提交的快速追加之后都会更新，
    /// 一旦宽房间负载触及上限，这里若做一次 O(n) 字典扫描，
    /// 就会把所有调用方串行阻塞在缓存 actor 之后。
    /// 一旦大房间负载触及容量上限，这里的 O(n) 字典扫描会让所有调用方排在缓存 actor 之后。
    private final class Node {
        let key: Key
        var entry: Entry
        var expiresAt: ContinuousClock.Instant

        weak var previous: Node?
        var next: Node?

        init(key: Key, entry: Entry, expiresAt: ContinuousClock.Instant) {
            self.key = key
            self.entry = entry
            self.expiresAt = expiresAt
        }
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [Key: Node] = [:]
    private var keysByRoomID: [UUID: Set<Key>] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var lookupHits: Int64 = 0
    private var lookupMisses: Int64 = 0
    private var attemptedAppends: Int64 = 0
    private var committedAppends: Int64 = 0
    private var fallbackAppends: Int64 = 0
    private var insertions: UInt64 = 0
    private var evictions: UInt64 = 0
    private var expirations: UInt64 = 0

    public init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    public func value(for key: Key) -> Entry? {
        let now = clock.now
        guard let node = entries[key] else {
            lookupMisses = saturatingCacheCounter(lookupMisses, adding: 1)
            return nil
        }
        guard node.expiresAt > now else {
            remove(node)
            expirations &+= 1
            lookupMisses = saturatingCacheCounter(lookupMisses, adding: 1)
            return nil
        }
        lookupHits = saturatingCacheCounter(lookupHits, adding: 1)
        moveToMostRecent(node)
        return node.entry
    }

    /// 以一次 actor 跳转完成一个微批的查询。
    ///
    /// 访问新旧顺序仍按请求顺序更新，因此最终 LRU 状态与逐条调用 `value(for:)` 完全一致，
    /// 而调用方不必为此串行等待 N 次。
    public func valuesIfAllPresent(for keys: [Key]) -> [Entry]? {
        var values: [Entry] = []
        values.reserveCapacity(keys.count)
        for key in keys {
            guard let value = value(for: key) else { return nil }
            values.append(value)
        }
        return values
    }

    /// 通过一次 actor 跳转解析一个分类器批次，同时为每个键保留与标量路径
    /// 完全一致的查找、过期与 LRU 语义。
    ///
    /// - Parameter keys: 本次要解析的缓存键列表。
    /// - Returns: 与 `keys` 顺序一致的条目结果，未命中或已过期处为 `nil`。
    public func values(for keys: [Key]) -> [Entry?] {
        keys.map { value(for: $0) }
    }

    public func insert(_ entry: Entry, for key: Key) {
        let now = clock.now
        if let existing = entries[key] {
            existing.entry = entry
            existing.expiresAt = now + lifetime
            moveToMostRecent(existing)
            return
        }
        if entries.count >= capacity, let leastRecent {
            remove(leastRecent)
            evictions &+= 1
        }
        let node = Node(key: key, entry: entry, expiresAt: now + lifetime)
        entries[key] = node
        keysByRoomID[key.roomID, default: []].insert(key)
        attachAsMostRecent(node)
        insertions &+= 1
    }

    /// 通过一次 actor 跳转发布一个已提交微批。
    ///
    /// 输入顺序即持久化的房间顺序，
    /// 因此重复出现的房间/发送者键会自然在缓存中留下其最新的已提交游标。
    ///
    /// - Parameter updates: 已提交的缓存更新列表。
    func insert(_ updates: [Update]) {
        for update in updates {
            insert(update.entry, for: update.key)
        }
    }

    struct RecipientReplyUpdate: Sendable {
        let key: Key
        let expectedDirectPairRevision: Int64
    }

    /// 在对端首次发送提交之后晋升反方向。
    ///
    /// 修订相等校验可以防止乱序的提交后回调改写更新的授权快照。
    ///
    /// - Parameter updates: 待标记的接收方已回复更新列表。
    func markRecipientsHaveReplied(_ updates: [RecipientReplyUpdate]) {
        let now = clock.now
        for update in updates {
            guard let node = entries[update.key],
                  node.expiresAt > now,
                  node.entry.policy.directPairRevision == update.expectedDirectPairRevision,
                  !node.entry.policy.recipientHasReplied
            else { continue }
            node.entry = .init(
                policy: node.entry.policy.markingRecipientHasReplied(),
                roomShardID: node.entry.roomShardID,
                capacityProfileID: node.entry.capacityProfileID,
                membershipRevision: node.entry.membershipRevision,
                shardState: node.entry.shardState
            )
            node.expiresAt = now + lifetime
            moveToMostRecent(node)
        }
    }

    /// 使某个方向的缓存条目失效。
    ///
    /// 未命中可能意味着并发发送、权限变更、成员变更、租约替换或幂等重放。
    /// 这里只移除当前方向；完整路径会在其事务提交后重新填充。
    ///
    /// - Parameter key: 待失效的缓存键。
    public func invalidate(_ key: Key) {
        guard let node = entries[key] else { return }
        remove(node)
    }

    public func invalidate(roomID: UUID) {
        guard let keys = keysByRoomID[roomID] else { return }
        for key in keys {
            if let node = entries[key] {
                remove(node, updateRoomIndex: false)
            }
        }
        keysByRoomID.removeValue(forKey: roomID)
    }

    /// 记录尝试次数。
    ///
    /// 这些计数器刻意只用于本机可观测性。它们可以证明某次测试或灰度确实走到了
    /// 条件 SQL 分支；它们绝不参与授权判定。
    ///
    /// - Parameter count: 本次记录的尝试次数，负数按零处理。
    public func recordAttempt(count: Int) {
        attemptedAppends = saturatingCacheCounter(attemptedAppends, adding: Int64(max(0, count)))
    }

    public func recordCommitted(count: Int) {
        committedAppends = saturatingCacheCounter(committedAppends, adding: Int64(max(0, count)))
    }

    public func recordFallback(count: Int) {
        fallbackAppends = saturatingCacheCounter(fallbackAppends, adding: Int64(max(0, count)))
    }

    public func snapshot() -> V2DirectRoomLogFastAppendCacheSnapshot {
        .init(
            entries: entries.count,
            lookupHits: lookupHits,
            lookupMisses: lookupMisses,
            attemptedAppends: attemptedAppends,
            committedAppends: committedAppends,
            fallbackAppends: fallbackAppends,
            insertions: insertions,
            evictions: evictions,
            expirations: expirations
        )
    }

    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        detach(node)
        attachAsMostRecent(node)
    }

    private func attachAsMostRecent(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil {
            leastRecent = node
        }
    }

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

    private func remove(_ node: Node, updateRoomIndex: Bool = true) {
        detach(node)
        entries.removeValue(forKey: node.key)
        if updateRoomIndex {
            keysByRoomID[node.key.roomID]?.remove(node.key)
            if keysByRoomID[node.key.roomID]?.isEmpty == true {
                keysByRoomID.removeValue(forKey: node.key.roomID)
            }
        }
    }
}

/// 饱和累加计数器。
///
/// 可观测性计数器绝不分配持久序号或修订。
/// 饱和处理在保持指标单调的同时，不会打断消息处理流程。
private func saturatingCacheCounter(_ current: Int64, adding count: Int64) -> Int64 {
    let result = current.addingReportingOverflow(count)
    return result.overflow ? .max : result.partialValue
}
