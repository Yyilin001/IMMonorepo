import Foundation
import IMV2Core

/// A short-lived, process-local snapshot for the ordinary direct room-log
/// append fast path.
///
/// This cache is deliberately not an authorization or ordering authority.
/// Every accepted append still compares the stored room sequence, membership
/// revision, direct-pair revision and both user-policy revisions while
/// holding the corresponding PostgreSQL locks. A stale entry therefore turns
/// into an internal fast-path miss and is retried through the established
/// complete acceptance path.
public actor V2DirectRoomLogFastAppendCache {
    struct Update: Sendable {
        let entry: Entry
        let key: Key
    }

    public struct Snapshot: Sendable, Equatable {
        public let entries: Int
        public let lookupHits: Int64
        public let lookupMisses: Int64
        public let attemptedAppends: Int64
        public let committedAppends: Int64
        public let fallbackAppends: Int64
        public let insertions: UInt64
        public let evictions: UInt64
        public let expirations: UInt64

        public init(
            entries: Int,
            lookupHits: Int64,
            lookupMisses: Int64,
            attemptedAppends: Int64,
            committedAppends: Int64,
            fallbackAppends: Int64,
            insertions: UInt64 = 0,
            evictions: UInt64 = 0,
            expirations: UInt64 = 0
        ) {
            self.entries = entries
            self.lookupHits = lookupHits
            self.lookupMisses = lookupMisses
            self.attemptedAppends = attemptedAppends
            self.committedAppends = committedAppends
            self.fallbackAppends = fallbackAppends
            self.insertions = insertions
            self.evictions = evictions
            self.expirations = expirations
        }
    }

    public struct Key: Hashable, Sendable {
        public let roomID: UUID
        public let senderID: UUID

        public init(roomID: UUID, senderID: UUID) {
            self.roomID = roomID
            self.senderID = senderID
        }
    }

    /// The immutable-by-revision policy snapshot required to construct a
    /// conditional append attempt. Room cursors deliberately do not live in
    /// this entry: another producer may advance a direct room at any time,
    /// while PostgreSQL can safely allocate the next sequence under its room
    /// row lock. Coupling that high-churn cursor to the stable policy made a
    /// valid authorization cache miss whenever the peer sent a message.
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

    /// Actor-isolated intrusive LRU node. A capacity eviction must remain O(1):
    /// this cache is updated after every committed fast append, and an O(n)
    /// dictionary scan here serializes every caller behind the cache actor once
    /// a wide-room workload reaches the bound.
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
            lookupMisses += 1
            return nil
        }
        guard node.expiresAt > now else {
            remove(node)
            expirations &+= 1
            lookupMisses += 1
            return nil
        }
        lookupHits += 1
        moveToMostRecent(node)
        return node.entry
    }

    /// One actor hop for a micro-batch. Recency is still applied in request
    /// order, so the final LRU state is identical to repeated `value(for:)`
    /// calls without serializing the caller through N separate awaits.
    public func valuesIfAllPresent(for keys: [Key]) -> [Entry]? {
        var values: [Entry] = []
        values.reserveCapacity(keys.count)
        for key in keys {
            guard let value = value(for: key) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Resolves a classifier batch with one actor hop while preserving the
    /// exact scalar lookup, expiry and LRU semantics for every key.
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

    /// Publishes a committed micro-batch with one actor hop. The input order is
    /// durable room order, so a repeated room/sender key naturally leaves its
    /// newest committed cursor in the cache.
    func insert(_ updates: [Update]) {
        for update in updates {
            insert(update.entry, for: update.key)
        }
    }

    struct RecipientReplyUpdate: Sendable {
        let key: Key
        let expectedDirectPairRevision: Int64
    }

    /// Promotes the opposite direction after a first send commits. Revision
    /// equality prevents an out-of-order post-commit callback from rewriting
    /// a newer authorization snapshot.
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

    /// A miss may mean a concurrent send, permission change, membership
    /// change, lease replacement or an idempotent replay. Remove only this
    /// direction; the full path will repopulate it after its transaction
    /// commits.
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

    /// These counters are deliberately local observability only. They make
    /// it possible to prove that a test or rollout actually exercised the
    /// conditional SQL branch; they never participate in authorization.
    public func recordAttempt(count: Int) {
        attemptedAppends += Int64(max(0, count))
    }

    public func recordCommitted(count: Int) {
        committedAppends += Int64(max(0, count))
    }

    public func recordFallback(count: Int) {
        fallbackAppends += Int64(max(0, count))
    }

    public func snapshot() -> Snapshot {
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
