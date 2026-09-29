import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// 私聊授权中稳定部分的进程内加速缓存。
///
/// 它刻意不承担授权权威：每次命中都携带持久化修订栅栏，
/// 消息被接受之前仍由 PostgreSQL 逐项校验。
public actor V2DirectSendPolicyCache {
    struct Update: Sendable {
        let entry: Entry
        let key: Key
    }

    /// 缓存键，由房间与发送者确定。
    public struct Key: Hashable, Sendable {
        /// 私聊房间标识。
        public let roomID: UUID
        /// 发送者标识。
        public let senderID: UUID

        /// 保存缓存键。
        ///
        /// - Parameters:
        ///   - roomID: 私聊房间标识。
        ///   - senderID: 发送者标识。
        public init(roomID: UUID, senderID: UUID) {
            self.roomID = roomID
            self.senderID = senderID
        }
    }

    /// 单个发送方向的策略快照。
    public struct Entry: Sendable, Equatable {
        public let recipientID: UUID
        public let directPairRevision: Int64
        public let senderPolicyRevision: Int64
        public let recipientPolicyRevision: Int64
        public let senderProfileVisibleToRecipient: Bool
        public let senderCanSend: Bool?
        /// 持久化预检观察到的发送者资料与账号活跃状态。
        ///
        /// 只有配合发送者策略修订栅栏才能复用：账号停用会在同一事务内递增该修订。
        public let senderIsActive: Bool
        public let recipientIsActive: Bool
        public let blocked: Bool
        public let isFriend: Bool
        /// 来自 `direct_room_pairs` 的发送者维度单调状态。
        ///
        /// 一旦为真便不会回退，因此可以安全地用于避免后续发送中一次本无效果的回复标记写入。
        public let senderHasReplied: Bool
        public let recipientHasReplied: Bool
        public let allowsStrangers: Bool
        public let senderAccountKind: String?
        public let senderAccountStatus: String?
        public let senderAllowsServiceMessages: Bool?
        public let recipientAccountKind: String?
        public let recipientAccountStatus: String?
        public let recipientAllowsCustomerMessages: Bool?

        public init(
            recipientID: UUID,
            directPairRevision: Int64,
            senderPolicyRevision: Int64,
            recipientPolicyRevision: Int64,
            senderProfileVisibleToRecipient: Bool,
            senderCanSend: Bool?,
            senderIsActive: Bool,
            recipientIsActive: Bool,
            blocked: Bool,
            isFriend: Bool,
            senderHasReplied: Bool,
            recipientHasReplied: Bool,
            allowsStrangers: Bool,
            senderAccountKind: String?,
            senderAccountStatus: String?,
            senderAllowsServiceMessages: Bool?,
            recipientAccountKind: String?,
            recipientAccountStatus: String?,
            recipientAllowsCustomerMessages: Bool?
        ) {
            self.recipientID = recipientID
            self.directPairRevision = directPairRevision
            self.senderPolicyRevision = senderPolicyRevision
            self.recipientPolicyRevision = recipientPolicyRevision
            self.senderProfileVisibleToRecipient = senderProfileVisibleToRecipient
            self.senderCanSend = senderCanSend
            self.senderIsActive = senderIsActive
            self.recipientIsActive = recipientIsActive
            self.blocked = blocked
            self.isFriend = isFriend
            self.senderHasReplied = senderHasReplied
            self.recipientHasReplied = recipientHasReplied
            self.allowsStrangers = allowsStrangers
            self.senderAccountKind = senderAccountKind
            self.senderAccountStatus = senderAccountStatus
            self.senderAllowsServiceMessages = senderAllowsServiceMessages
            self.recipientAccountKind = recipientAccountKind
            self.recipientAccountStatus = recipientAccountStatus
            self.recipientAllowsCustomerMessages = recipientAllowsCustomerMessages
        }

        /// 构造「发送者已回复」的派生条目。
        ///
        /// 消息接受与本次缓存发布分别位于数据库提交的两侧，因此该派生不会对外宣布尚未提交的
        /// 回复标记；同时用户对修订会在同一次变更中变化，派生条目也会保留可用的修订栅栏。
        ///
        /// - Returns: 已回复标记为真的派生条目。
        func markingSenderHasReplied() -> Self {
            .init(
                recipientID: recipientID,
                directPairRevision: directPairRevision + 1,
                senderPolicyRevision: senderPolicyRevision,
                recipientPolicyRevision: recipientPolicyRevision,
                senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
                senderCanSend: senderCanSend,
                senderIsActive: senderIsActive,
                recipientIsActive: recipientIsActive,
                blocked: blocked,
                isFriend: isFriend,
                senderHasReplied: true,
                recipientHasReplied: recipientHasReplied,
                allowsStrangers: allowsStrangers,
                senderAccountKind: senderAccountKind,
                senderAccountStatus: senderAccountStatus,
                senderAllowsServiceMessages: senderAllowsServiceMessages,
                recipientAccountKind: recipientAccountKind,
                recipientAccountStatus: recipientAccountStatus,
                recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
            )
        }

        /// 把对端首次已提交发送应用到本方向的缓存条目。
        ///
        /// 调用方需自行提供并校验此前的持久化用户对修订；该标记在 PostgreSQL 中是单调的。
        ///
        /// - Returns: 对端已回复标记为真的派生条目。
        func markingRecipientHasReplied() -> Self {
            .init(
                recipientID: recipientID,
                directPairRevision: directPairRevision + 1,
                senderPolicyRevision: senderPolicyRevision,
                recipientPolicyRevision: recipientPolicyRevision,
                senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
                senderCanSend: senderCanSend,
                senderIsActive: senderIsActive,
                recipientIsActive: recipientIsActive,
                blocked: blocked,
                isFriend: isFriend,
                senderHasReplied: senderHasReplied,
                recipientHasReplied: true,
                allowsStrangers: allowsStrangers,
                senderAccountKind: senderAccountKind,
                senderAccountStatus: senderAccountStatus,
                senderAllowsServiceMessages: senderAllowsServiceMessages,
                recipientAccountKind: recipientAccountKind,
                recipientAccountStatus: recipientAccountStatus,
                recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
            )
        }
    }

    /// actor 隔离的侵入式 LRU 节点。
    ///
    /// 字典查找、最近使用刷新、插入与容量淘汰均为 O(1)。
    /// 此前使用 `Dictionary.min` 做淘汰，缓存达到容量后每次都要扫描全部策略，
    /// 从而形成陡峭的吞吐断层。
    private final class Node {
        let key: Key
        var value: Entry
        var expiresAt: ContinuousClock.Instant
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Entry, expiresAt: ContinuousClock.Instant) {
            self.key = key
            self.value = value
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
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var insertions: UInt64 = 0
    private var evictions: UInt64 = 0
    private var expirations: UInt64 = 0

    /// 创建容量与有效期有界的策略缓存。
    ///
    /// - Parameters:
    ///   - capacity: 条目容量上限，小于一时按一处理。
    ///   - lifetime: 条目有效期，小于一秒时按一秒处理。
    public init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    /// 查询某发送方向的策略快照。
    ///
    /// 过期条目会在查询时移除并返回 `nil`，有效命中会被提升为最近使用。
    ///
    /// - Parameter key: 缓存键。
    /// - Returns: 有效快照；缺失或已过期时为 `nil`。
    public func value(for key: Key) -> Entry? {
        let now = clock.now
        guard let node = entries[key] else {
            misses &+= 1
            return nil
        }
        guard node.expiresAt > now else {
            remove(node)
            expirations &+= 1
            misses &+= 1
            return nil
        }
        moveToMostRecent(node)
        hits &+= 1
        return node.value
    }

    /// 通过一次 actor 跳转解析一个有界且保序的微批。
    ///
    /// 每个键仍会经过 `value(for:)`，因此过期判定、命中/未命中统计以及 LRU 最近使用
    /// 与重复的标量查找完全一致。唯一省去的开销是：在一个已经合并过的 PostgreSQL 批次里，
    /// 不再为每条消息各发生一次跨执行器挂起。
    ///
    /// - Parameter keys: 本次要解析的缓存键列表。
    /// - Returns: 与 `keys` 顺序一致的条目结果，未命中或已过期处为 `nil`。
    func values(for keys: [Key]) -> [Entry?] {
        keys.map { value(for: $0) }
    }

    /// 写入或更新一条策略快照。
    ///
    /// - Parameters:
    ///   - value: 策略快照。
    ///   - key: 缓存键。
    public func insert(_ value: Entry, for key: Key) {
        let now = clock.now
        if let existing = entries[key] {
            existing.value = value
            existing.expiresAt = now + lifetime
            moveToMostRecent(existing)
            return
        }
        if entries.count >= capacity, let leastRecent {
            remove(leastRecent)
            evictions &+= 1
        }
        let node = Node(key: key, value: value, expiresAt: now + lifetime)
        entries[key] = node
        keysByRoomID[key.roomID, default: []].insert(key)
        attachAsMostRecent(node)
        insertions &+= 1
    }

    /// 通过一次 actor 跳转，按持久化顺序应用一个已提交微批。
    ///
    /// 出现重复键是刻意允许的：最后提交的修订才是必须保持可见的缓存状态。
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

    /// 只推进那些被证明描述了「对端首次发送已提交之前的那一版」配对修订的缓存条目。
    ///
    /// 缺失或更新的条目保持不动，它们会由常规的修订围栏数据库路径刷新。
    ///
    /// - Parameter updates: 待标记的接收方已回复更新列表。
    func markRecipientsHaveReplied(_ updates: [RecipientReplyUpdate]) {
        let now = clock.now
        for update in updates {
            guard let node = entries[update.key],
                  node.expiresAt > now,
                  node.value.directPairRevision == update.expectedDirectPairRevision,
                  !node.value.recipientHasReplied
            else { continue }
            node.value = node.value.markingRecipientHasReplied()
            node.expiresAt = now + lifetime
            moveToMostRecent(node)
        }
    }

    /// 移除指定缓存键。
    ///
    /// - Parameter key: 缓存键。
    public func invalidate(_ key: Key) {
        guard let node = entries[key] else { return }
        remove(node)
    }

    /// 移除指定房间下全部发送方向的缓存。
    ///
    /// - Parameter roomID: 目标房间。
    public func invalidate(roomID: UUID) {
        guard let keys = keysByRoomID[roomID] else { return }
        for key in keys {
            if let node = entries[key] {
                remove(node, updateRoomIndex: false)
            }
        }
        keysByRoomID.removeValue(forKey: roomID)
    }

    /// 清空全部缓存条目，不清零统计计数。
    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysByRoomID.removeAll(keepingCapacity: true)
        mostRecent = nil
        leastRecent = nil
    }

    /// 读取当前缓存快照。
    ///
    /// - Returns: 条目数与各项累计计数。
    public func snapshot() -> V2DirectSendPolicyCacheSnapshot {
        .init(
            entries: entries.count,
            hits: hits,
            misses: misses,
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


// 每次使用控制域事实，都必须在控制域事务中刷新；
// 所有者版本号只为回复／投影及所有者本地结构设置栅栏。
extension V2DirectSendPolicyCache.Entry {
    func applyingControlPolicy(_ control: V2DirectSendControlPolicy) -> Self {
        .init(recipientID: recipientID, directPairRevision: directPairRevision,
            senderPolicyRevision: senderPolicyRevision, recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient, senderCanSend: senderCanSend,
            senderIsActive: control.sender.isActive, recipientIsActive: control.recipient.isActive,
            blocked: control.blocked, isFriend: control.isFriend,
            senderHasReplied: senderHasReplied, recipientHasReplied: recipientHasReplied,
            allowsStrangers: control.allowsStrangers,
            senderAccountKind: control.sender.specialKind, senderAccountStatus: control.sender.specialStatus,
            senderAllowsServiceMessages: control.sender.allowsServiceMessages,
            recipientAccountKind: control.recipient.specialKind, recipientAccountStatus: control.recipient.specialStatus,
            recipientAllowsCustomerMessages: control.recipient.allowsCustomerMessages)
    }
}
