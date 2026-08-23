import Foundation

/// Process-local acceleration for the stable portion of direct-message
/// authorization. It is deliberately not an authorization authority: every
/// hit carries durable revision fences that PostgreSQL verifies before a
/// message can be accepted.
public actor V2DirectSendPolicyCache {
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

    private struct StoredEntry: Sendable {
        var value: Entry
        var expiresAt: ContinuousClock.Instant
        var lastAccess: ContinuousClock.Instant
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [Key: StoredEntry] = [:]

    public init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    public func value(for key: Key) -> Entry? {
        let now = clock.now
        guard var stored = entries[key] else { return nil }
        guard stored.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        stored.lastAccess = now
        entries[key] = stored
        return stored.value
    }

    public func insert(_ value: Entry, for key: Key) {
        let now = clock.now
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = .init(value: value, expiresAt: now + lifetime, lastAccess: now)
    }

    public func invalidate(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    public func invalidate(roomID: UUID) {
        entries = entries.filter { $0.key.roomID != roomID }
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
