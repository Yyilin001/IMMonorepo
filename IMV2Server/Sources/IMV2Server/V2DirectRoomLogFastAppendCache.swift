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
    public struct Snapshot: Sendable, Equatable {
        public let entries: Int
        public let lookupHits: Int64
        public let lookupMisses: Int64
        public let attemptedAppends: Int64
        public let committedAppends: Int64
        public let fallbackAppends: Int64
    }

    public struct Key: Hashable, Sendable {
        public let roomID: UUID
        public let senderID: UUID

        public init(roomID: UUID, senderID: UUID) {
            self.roomID = roomID
            self.senderID = senderID
        }
    }

    /// The last committed room cursor plus the immutable-by-revision policy
    /// snapshot required to construct a conditional append attempt.
    public struct Entry: Sendable {
        public let policy: V2DirectSendPolicyCache.Entry
        public let roomShardID: String
        public let capacityProfileID: String
        public let expectedRoomSequence: Int64
        public let expectedTimelineSequence: Int64
        public let membershipRevision: Int64
        public let shardState: ShardAdmissionState

        public init(
            policy: V2DirectSendPolicyCache.Entry,
            roomShardID: String,
            capacityProfileID: String,
            expectedRoomSequence: Int64,
            expectedTimelineSequence: Int64,
            membershipRevision: Int64,
            shardState: ShardAdmissionState
        ) {
            self.policy = policy
            self.roomShardID = roomShardID
            self.capacityProfileID = capacityProfileID
            self.expectedRoomSequence = expectedRoomSequence
            self.expectedTimelineSequence = expectedTimelineSequence
            self.membershipRevision = membershipRevision
            self.shardState = shardState
        }

        func advancing(
            roomSequence: Int64,
            timelineSequence: Int64
        ) -> Self {
            .init(
                policy: policy,
                roomShardID: roomShardID,
                capacityProfileID: capacityProfileID,
                expectedRoomSequence: roomSequence,
                expectedTimelineSequence: timelineSequence,
                membershipRevision: membershipRevision,
                shardState: shardState
            )
        }
    }

    private struct Stored: Sendable {
        var entry: Entry
        var expiresAt: ContinuousClock.Instant
        var lastAccess: ContinuousClock.Instant
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [Key: Stored] = [:]
    private var lookupHits: Int64 = 0
    private var lookupMisses: Int64 = 0
    private var attemptedAppends: Int64 = 0
    private var committedAppends: Int64 = 0
    private var fallbackAppends: Int64 = 0

    public init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    public func value(for key: Key) -> Entry? {
        let now = clock.now
        guard var stored = entries[key] else {
            lookupMisses += 1
            return nil
        }
        guard stored.expiresAt > now else {
            entries.removeValue(forKey: key)
            lookupMisses += 1
            return nil
        }
        lookupHits += 1
        stored.lastAccess = now
        entries[key] = stored
        return stored.entry
    }

    public func insert(_ entry: Entry, for key: Key) {
        let now = clock.now
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = .init(entry: entry, expiresAt: now + lifetime, lastAccess: now)
    }

    /// A miss may mean a concurrent send, permission change, membership
    /// change, lease replacement or an idempotent replay. Remove only this
    /// direction; the full path will repopulate it after its transaction
    /// commits.
    public func invalidate(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    public func invalidate(roomID: UUID) {
        entries = entries.filter { $0.key.roomID != roomID }
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
            fallbackAppends: fallbackAppends
        )
    }
}
