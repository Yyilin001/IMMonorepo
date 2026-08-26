import Foundation

/// Process-local acceleration for the stable portion of direct-message
/// authorization. It is deliberately not an authorization authority: every
/// hit carries durable revision fences that PostgreSQL verifies before a
/// message can be accepted.
public actor V2DirectSendPolicyCache {
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

    public struct Entry: Sendable, Equatable {
        public let recipientID: UUID
        public let directPairRevision: Int64
        public let senderPolicyRevision: Int64
        public let recipientPolicyRevision: Int64
        public let senderProfileVisibleToRecipient: Bool
        public let senderCanSend: Bool?
        /// The sender profile/account activity observed by the durable
        /// preflight. It may be reused only with the sender policy revision
        /// fence; account disable increments that revision in the same
        /// transaction.
        public let senderIsActive: Bool
        public let recipientIsActive: Bool
        public let blocked: Bool
        public let isFriend: Bool
        /// Monotonic, sender-specific state from `direct_room_pairs`. Once it
        /// becomes true it never reverts, so it is safe to use only to avoid
        /// an otherwise no-op reply-marker write on subsequent sends.
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

        /// The accepted message and this cache publication happen on opposite
        /// sides of the database commit. Therefore this refinement never
        /// advertises an uncommitted reply marker. The pair revision changes
        /// in the same mutation, so retain a usable revision fence as well.
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
    }

    public struct Snapshot: Equatable, Sendable {
        public let entries: Int
        public let hits: UInt64
        public let misses: UInt64
        public let insertions: UInt64
        public let evictions: UInt64
        public let expirations: UInt64
    }

    /// Actor-isolated intrusive LRU node. Dictionary lookup, recency refresh,
    /// insertion and capacity eviction are all O(1); the previous
    /// `Dictionary.min` eviction scanned every cached policy after the cache
    /// reached capacity and created a sharp throughput cliff.
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

    public init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

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

    /// Applies a committed micro-batch in its durable order using one actor
    /// hop. Repeated keys are intentional: the last committed revision is the
    /// cache state that must remain visible.
    func insert(_ updates: [Update]) {
        for update in updates {
            insert(update.entry, for: update.key)
        }
    }

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

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysByRoomID.removeAll(keepingCapacity: true)
        mostRecent = nil
        leastRecent = nil
    }

    public func snapshot() -> Snapshot {
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
