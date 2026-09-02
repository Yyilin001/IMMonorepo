import Crypto
import Foundation
import IMV2Core
import Synchronization

/// Values that are available only after a transport has authenticated the
/// caller.  The public protocol decoder must never be allowed to supply the
/// sender id directly.
public struct V2AuthenticatedSendMessage: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?

    public init(roomID: RoomID, actorUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

public enum V2SendMessageOutcome: Equatable, Sendable {
    case accepted(V2AcceptedMessage)
    case idempotent(V2AcceptedMessage)
    case idempotencyConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
    /// The server persisted a private activity and composer capability for
    /// this exact operation. No message, room event or fan-out plan exists.
    case denied(V2DirectMessageDenied)
}

public struct V2DirectMessageDenied: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case generic
        case systemAccountReadOnly = "system_account_read_only"
    }

    public let roomID: RoomID
    public let sourceEventID: EventID
    public let timelineSequence: UInt64
    public let createdAt: Date
    public let reason: Reason

    public init(roomID: RoomID, sourceEventID: EventID, timelineSequence: UInt64, createdAt: Date, reason: Reason = .generic) {
        precondition(timelineSequence > 0)
        self.roomID = roomID
        self.sourceEventID = sourceEventID
        self.timelineSequence = timelineSequence
        self.createdAt = createdAt
        self.reason = reason
    }
}

/// Binds a runtime capacity policy to the persisted room profile identifier.
/// A policy may never be selected only by process-wide default configuration.
public struct V2CapacityProfile: Equatable, Sendable {
    public let id: String
    public let limits: RoomCapacityProfile

    public init(id: String, limits: RoomCapacityProfile) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw V2CapacityProfileError.invalidIdentifier }
        self.id = normalized
        self.limits = limits
    }
}

public enum V2CapacityProfileError: Error, Equatable, Sendable { case invalidIdentifier }

/// The persistence boundary owns row locking and the database transaction.
/// Its successful implementation must persist the entire Core transaction
/// value, never just the message row.
public protocol V2RoomWriteStore: Sendable {
    func accept(
        command: consuming V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome
}

/// An immutable acceptance request prepared by the domain layer.  Keeping the
/// generated identifiers with the request is essential: an ordered batch may
/// retry its PostgreSQL transaction, but it must never mint a second message
/// or event identity for the same client operation.
public struct V2RoomWriteRequest: Sendable {
    public let command: V2SendMessageCommand
    public let capacityProfile: V2CapacityProfile
    public let identifiers: V2AcceptanceIdentifiers
    public let now: Date

    public init(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) {
        self.command = command
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }
}

/// A store that can make a compatible ordered input subset durable atomically.
///
/// This is deliberately a separate protocol rather than a convenience method
/// on `V2RoomWriteStore`. The batcher keeps the result for every independent
/// command, so an implementation can atomically commit the subset it has
/// classified as compatible while the remaining distinct rooms use their
/// ordinary durable path. A false classification is never an authorization
/// outcome and cannot be returned to a client.
public protocol V2AtomicRoomWriteBatchStore: V2RoomWriteStore {
    /// A process-local, advisory classification for one pending batch.
    ///
    /// `true` means the implementation expects the request to be eligible for
    /// its shared transaction fast path.  It is never an authorization
    /// decision: a later atomic attempt must still take every authoritative
    /// lock and may decline the request when a durable revision changed.  A
    /// `false` result merely lets the batcher send that independent request
    /// through the established one-command path without making unrelated,
    /// eligible requests give up their set-based transaction.
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool]

    /// Advisory compatibility key for each request. Equal non-nil keys may
    /// share one atomic store call; different keys remain independently
    /// batched instead of forcing the faster class through the slower SQL
    /// graph. `nil` retains the ordinary one-command path.
    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?]

    /// Whether one compatibility class can advance the same room more than
    /// once inside a single ordered transaction. The default remains false:
    /// stores must opt in only after their reducer and persistence statement
    /// both collapse the final room state without dropping intermediate
    /// messages.
    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool

    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]
}

public extension V2AtomicRoomWriteBatchStore {
    /// Stores that do not expose a cheap advisory classifier retain the
    /// original all-or-nothing attempt behaviour.  This keeps the classifier
    /// an optimisation rather than a new requirement for correctness.
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        Array(repeating: true, count: requests.count)
    }


    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        let eligibility = await atomicBatchEligibility(requests: requests)
        guard eligibility.count == requests.count else {
            return Array(repeating: nil, count: requests.count)
        }
        return eligibility.map { $0 ? .standard : nil }
    }

    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool {
        false
    }
}

/// Opaque, store-defined compatibility class. It never represents an
/// authorization result; PostgreSQL remains authoritative for every class.
public struct V2AtomicRoomWriteBatchPartition: Hashable, Sendable {
    public static let standard = Self(rawValue: 0)
    public static let accelerated = Self(rawValue: 1)
    /// Plain, no-mention messages in a large-group room-log room. This class
    /// never shares a transaction with the direct-message policy graph.
    public static let largeGroupHybrid = Self(rawValue: 2)

    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// A batch implementation may decline a shape that cannot preserve the
/// ordinary command semantics in a shared transaction (for example a command
/// with attachments or a room that requires a policy side effect).  The
/// batcher then retries the original immutable requests through the ordinary
/// per-command path.  This is distinct from a storage error: it is never
/// exposed to a client and never acknowledges a partial batch.
///
/// Reasons are deliberately low-cardinality operational dimensions. They
/// must never contain a room, user, operation or policy identifier.
public struct V2AtomicRoomWriteBatchError: Error, Equatable, Sendable {
    public enum Reason: String, CaseIterable, Hashable, Sendable {
        case unspecified
        case incompatibleConfiguration = "incompatible_configuration"
        case requestShape = "request_shape"
        case duplicateOperation = "duplicate_operation"
        case duplicateRoom = "duplicate_room"
        case preflightMismatch = "preflight_mismatch"
        case authorizationState = "authorization_state"
        case roomKindMismatch = "room_kind_mismatch"
        case capacityProfileMismatch = "capacity_profile_mismatch"
        case roomFrozen = "room_frozen"
        case roomCreditModeMismatch = "room_credit_mode_mismatch"
        case admissionState = "admission_state"
        case conditionalWriteMismatch = "conditional_write_mismatch"
    }

    /// Source-compatible value for stores that do not yet expose a bounded
    /// reason. New production rejection sites should prefer `init(reason:)`.
    public static let unsupportedRequestShape = Self(reason: .unspecified)

    public let reason: Reason
    /// Input-relative indices that are known to be individually incompatible
    /// while the rest of the rolled-back batch may still use the atomic path.
    /// This never carries an identifier and is validated by the batcher before
    /// it is used to isolate exceptional requests.
    public let isolatedRequestIndices: [Int]

    public init(reason: Reason, isolatedRequestIndices: [Int] = []) {
        self.reason = reason
        self.isolatedRequestIndices = isolatedRequestIndices
    }
}

public enum V2RoomWriteStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case actorNotEligible
    case actorMuted
    case roomFrozen
    case capacityProfileMismatch
    case corruptPersistenceState
    case directMessageBlocked
    case strangerMessagePermissionDenied
    case strangerMessageLimitReached
    case replyTargetNotFound
}

/// Process-local admission boundary for durable message acceptance.
///
/// A deployment may use one batching actor or a stable set of room-keyed
/// lanes.  Keeping the service dependent on this capability instead of one
/// concrete actor lets independent rooms use multiple executors without
/// weakening the per-room ordering contract.
public protocol V2SendMessageAdmission: Sendable {
    var managesForegroundWriteAdmission: Bool { get }
    /// `true` means the admission boundary submits accepted Hybrid group
    /// events at its ordered post-commit point before request continuations
    /// resume. Gateway handlers must then avoid publishing the same event a
    /// second time. Durable room-log recovery never depends on this hint.
    var publishesCommittedGroupEvents: Bool { get }

    func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome

    func snapshot() async -> V2SendMessageAdmissionBatcher.Snapshot
}

extension V2SendMessageAdmission {
    public var publishesCommittedGroupEvents: Bool { false }
}

public struct V2AcceptanceIDFactory: Sendable {
    private let makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers

    /// Production identifiers come from one process-secret HMAC expansion.
    /// Accepted entities use RFC 9562 UUIDv7 values: their shared millisecond
    /// prefix keeps PostgreSQL B-tree inserts local while each value retains
    /// 74 independently pseudorandom bits. The accepted timestamp is already
    /// part of the public message contract, so the UUID reveals no additional
    /// time precision. Linux also avoids Foundation's open/read/close sequence
    /// for every individual UUID.
    public init() {
        let generator = V2SecureProcessUUIDGenerator.shared
        makeIdentifiers = { acceptedAt in
            let identifiers = generator.makeOrderedTriple(at: acceptedAt)
            return V2AcceptanceIdentifiers(
                messageID: MessageID(uuid: identifiers.0),
                eventID: EventID(uuid: identifiers.1),
                planID: FanoutPlanID(uuid: identifiers.2)
            )
        }
    }

    /// Deterministic injection remains available for domain tests.
    public init(makeUUID: @escaping @Sendable () -> UUID) {
        makeIdentifiers = { _ in
            try V2AcceptanceIdentifiers(
                messageID: MessageID(makeUUID().uuidString),
                eventID: EventID(makeUUID().uuidString),
                planID: FanoutPlanID(makeUUID().uuidString)
            )
        }
    }

    public func make(at acceptedAt: Date) throws -> V2AcceptanceIdentifiers {
        try makeIdentifiers(acceptedAt)
    }
}

/// A process-local CSPRNG expansion for the three public identifiers created
/// by one accepted message. The 256-bit key is seeded by the platform secure
/// random source once. HMAC-SHA256 then gives every counter value a fresh
/// 256-bit pseudorandom block. Three disjoint 10-byte regions supply the 74
/// random bits of each standards-compliant UUIDv7; the two remaining bytes are
/// deliberately unused. No key, counter or derived relationship is exposed,
/// and a process restart receives a new key.
/// `SymmetricKey` in swift-crypto has immutable storage but its Linux module
/// does not yet declare `Sendable`. Concurrent operations only read that key;
/// the sole mutable field is the stdlib atomic counter.
final class V2SecureProcessUUIDGenerator: @unchecked Sendable {
    static let shared = V2SecureProcessUUIDGenerator()

    /// HMAC's keyed inner/outer hash states are invariant for the process.
    /// Copying this value before appending the unique counter preserves the
    /// exact HMAC(key, counter) construction while avoiding rebuilding the
    /// keyed SHA-256 inner and outer state for every accepted message.
    private let authenticationTemplate: HMAC<SHA256>
    private let authenticationCounter = Atomic<UInt64>(0)
    /// Trace and connection IDs never cross an authorization boundary. A
    /// process-random 56-bit namespace plus an injective 64-bit counter gives
    /// them process/restart uniqueness without paying for an HMAC on every
    /// heartbeat, pull and command. Public durable IDs still use the HMAC
    /// expansion below and retain their pseudorandom UUIDv7 contract.
    private let localIdentifierPrefix: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private let localIdentifierCounter = Atomic<UInt64>(0)
    private let lastOrderedUnixMilliseconds = Atomic<UInt64>(0)

    init() {
        let key = SymmetricKey(size: .bits256)
        authenticationTemplate = HMAC(key: key)
        localIdentifierPrefix = key.withUnsafeBytes { bytes in
            (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6])
        }
    }

    func makeOne() -> UUID {
        let increment = localIdentifierCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "process-local identifier space exhausted")
        let value = increment.newValue
        return UUID(uuid: (
            localIdentifierPrefix.0,
            localIdentifierPrefix.1,
            localIdentifierPrefix.2,
            localIdentifierPrefix.3,
            localIdentifierPrefix.4,
            localIdentifierPrefix.5,
            0x40 | UInt8(truncatingIfNeeded: value >> 60),
            UInt8(truncatingIfNeeded: value >> 52),
            0x80 | UInt8(truncatingIfNeeded: value >> 46) & 0x3f,
            UInt8(truncatingIfNeeded: value >> 38),
            UInt8(truncatingIfNeeded: value >> 30),
            UInt8(truncatingIfNeeded: value >> 22),
            UInt8(truncatingIfNeeded: value >> 14),
            UInt8(truncatingIfNeeded: value >> 6),
            UInt8(truncatingIfNeeded: value) & 0x3f,
            localIdentifierPrefix.6
        ))
    }

    func makeOrderedTriple(at date: Date) -> (UUID, UUID, UUID) {
        let unixMilliseconds = orderedUnixMilliseconds(for: date)
        let authenticationCode = nextAuthenticationCode()
        return authenticationCode.withUnsafeBytes { bytes in
            (
                v2UUIDv7(bytes, offset: 0, unixMilliseconds: unixMilliseconds),
                v2UUIDv7(bytes, offset: 10, unixMilliseconds: unixMilliseconds),
                v2UUIDv7(bytes, offset: 20, unixMilliseconds: unixMilliseconds)
            )
        }
    }

    /// A backwards wall-clock adjustment must not send new B-tree keys back
    /// into an older range. UUID uniqueness still comes from the HMAC output;
    /// this clamp only preserves the ordered prefix within one process.
    private func orderedUnixMilliseconds(for date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        precondition(milliseconds.isFinite && milliseconds >= 0)
        let candidate = UInt64(milliseconds.rounded(.down))
        precondition(candidate <= 0x0000_ffff_ffff_ffff, "UUIDv7 timestamp exhausted")
        var observed = lastOrderedUnixMilliseconds.load(ordering: .relaxed)
        while observed < candidate {
            let exchanged = lastOrderedUnixMilliseconds.compareExchange(
                expected: observed,
                desired: candidate,
                ordering: .relaxed
            )
            if exchanged.exchanged { return candidate }
            observed = exchanged.original
        }
        return observed
    }

    private func nextAuthenticationCode() -> HMAC<SHA256>.MAC {
        let increment = authenticationCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "acceptance identifier space exhausted")
        var input = increment.newValue.bigEndian
        return withUnsafeBytes(of: &input) { bytes in
            var authenticator = authenticationTemplate
            authenticator.update(data: Data(bytes))
            return authenticator.finalize()
        }
    }
}

private func v2UUIDv4<Bytes: RandomAccessCollection>(
    _ bytes: Bytes,
    offset: Int
) -> UUID where Bytes.Element == UInt8, Bytes.Index == Int {
    precondition(offset >= 0 && bytes.count >= offset + 16)
    let version = (bytes[offset + 6] & 0x0f) | 0x40
    let variant = (bytes[offset + 8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
        bytes[offset + 4], bytes[offset + 5], version, bytes[offset + 7],
        variant, bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
        bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
    ))
}

/// RFC 9562 section 5.7 layout. Bytes 0...5 are the 48-bit Unix millisecond
/// timestamp; all remaining non-version/non-variant bits come directly from
/// ten bytes of the process-secret HMAC expansion.
private func v2UUIDv7<Bytes: RandomAccessCollection>(
    _ bytes: Bytes,
    offset: Int,
    unixMilliseconds: UInt64
) -> UUID where Bytes.Element == UInt8, Bytes.Index == Int {
    precondition(offset >= 0 && bytes.count >= offset + 10)
    precondition(unixMilliseconds <= 0x0000_ffff_ffff_ffff)
    let versionAndRandom = (bytes[offset] & 0x0f) | 0x70
    let variantAndRandom = (bytes[offset + 2] & 0x3f) | 0x80
    return UUID(uuid: (
        UInt8(truncatingIfNeeded: unixMilliseconds >> 40),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 32),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 24),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 16),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 8),
        UInt8(truncatingIfNeeded: unixMilliseconds),
        versionAndRandom, bytes[offset + 1],
        variantAndRandom, bytes[offset + 3], bytes[offset + 4], bytes[offset + 5],
        bytes[offset + 6], bytes[offset + 7], bytes[offset + 8], bytes[offset + 9]
    ))
}

public struct V2SendMessageService: Sendable {
    private let store: any V2RoomWriteStore
    private let batcher: (any V2SendMessageAdmission)?
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let idFactory: V2AcceptanceIDFactory
    private let now: @Sendable () -> Date

    /// When enabled, the batcher takes foreground-write admission immediately
    /// around its actual database work. The gateway command boundary must not
    /// also reserve one permit per waiting message, otherwise a batching wait
    /// consumes the whole foreground lane before a transaction starts.
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    var publishesCommittedGroupEvents: Bool {
        batcher?.publishesCommittedGroupEvents ?? false
    }

    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        batcher: (any V2SendMessageAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.idFactory = idFactory
        self.now = now
    }

    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let command = try V2SendMessageCommand(
            roomID: request.roomID,
            senderUserID: request.actorUserID,
            clientMessageID: request.clientMessageID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo,
            limits: limits
        )
        let acceptedAt = now()
        let prepared = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(at: acceptedAt),
            now: acceptedAt
        )
        if let batcher {
            return try await batcher.accept(prepared)
        }
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}
