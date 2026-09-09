import Foundation
import IMV2Core

/// The identity of one shared shard-level admission pool.
///
/// A capacity profile ID is immutable: changing a limit requires a new profile
/// ID and an explicit room migration, never a silent in-place lease mutation.
public struct V2ShardAdmissionPoolKey: Equatable, Hashable, Sendable {
    public let roomShardID: String
    public let capacityProfileID: String

    public init(roomShardID: String, capacityProfileID: String) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = capacityProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty, !profile.isEmpty else {
            throw V2ShardAdmissionLeaseControlError.invalidPoolKey
        }
        self.roomShardID = shard
        self.capacityProfileID = profile
    }
}

/// The minimum fencing value a lease holder must present when it renews.
public struct V2ShardAdmissionLeaseFence: Equatable, Sendable {
    public let id: ShardAdmissionLeaseID
    public let generation: UInt64

    public init(id: ShardAdmissionLeaseID, generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

public extension ShardAdmissionLease {
    var v2Fence: V2ShardAdmissionLeaseFence {
        // The lease initializer already rejects zero generations.
        .init(id: id, generation: generation)
    }
}

public enum V2ShardAdmissionLeaseControlError: Error, Equatable, Sendable {
    case invalidPoolKey
    case invalidLifetime
    case capacityProfileDoesNotMatchPool
    case capacityProfileLimitsChanged
    case poolAlreadyExists
    case poolNotFound
    case fenceMismatch
    case leaseExpired
    case replacementRequiresExpiredLease
    case generationOverflow
}

/// Isolates the durable compare-and-swap operations needed by the control
/// plane. Implementations must serialize these operations per pool key.
public protocol V2ShardAdmissionLeaseStore: Sendable {
    func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        leaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease

    func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease

    func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        replacementLeaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease
}

/// Stateless use case for issuing, renewing and safely taking over shard
/// admission leases. A caller is responsible for authorizing access to this
/// internal control-plane API; it is deliberately not exposed by the public
/// realtime server executable.
public struct V2ShardAdmissionLeaseService: Sendable {
    private let store: any V2ShardAdmissionLeaseStore
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        store: any V2ShardAdmissionLeaseStore,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.makeUUID = makeUUID
        self.now = now
    }

    public func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        let validUntil = try expiry(after: lifetime, from: instant)
        return try await store.issue(
            key: key,
            capacityProfile: capacityProfile,
            leaseID: try .init(makeUUID().uuidString),
            validUntil: validUntil,
            now: instant
        )
    }

    public func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        return try await store.renew(
            key: key,
            expectedFence: expectedFence,
            validUntil: try expiry(after: lifetime, from: instant),
            now: instant
        )
    }

    public func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        return try await store.replaceExpired(
            key: key,
            capacityProfile: capacityProfile,
            replacementLeaseID: try .init(makeUUID().uuidString),
            validUntil: try expiry(after: lifetime, from: instant),
            now: instant
        )
    }

    private func expiry(after lifetime: TimeInterval, from instant: Date) throws -> Date {
        guard let expiry = v2PostgresFutureTimestamp(now: instant, interval: lifetime) else {
            throw V2ShardAdmissionLeaseControlError.invalidLifetime
        }
        return expiry
    }
}

func v2ShardLeaseMatchesProfile(_ lease: ShardAdmissionLease, _ profile: RoomCapacityProfile) -> Bool {
    lease.commandWindow.limit == profile.maxCommandsPerWindow
        && lease.fanoutWindow.limit == profile.maxFanoutUnitsPerWindow
        && lease.maxOutstandingFanoutUnits == profile.maxOutstandingFanoutUnits
        && lease.maxOutstandingPlans == profile.maxOutstandingPlans
}
