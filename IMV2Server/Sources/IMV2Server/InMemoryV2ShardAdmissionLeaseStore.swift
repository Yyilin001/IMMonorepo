import Foundation
import IMV2Core

/// Actor-isolated control-plane fixture. It models the same fencing rules as
/// PostgreSQL while keeping unit tests independent of an external database.
public actor InMemoryV2ShardAdmissionLeaseStore: V2ShardAdmissionLeaseStore {
    private var pools: [V2ShardAdmissionPoolKey: ShardAdmissionState]

    public init(seed: [(V2ShardAdmissionPoolKey, ShardAdmissionState)] = []) {
        self.pools = Dictionary(uniqueKeysWithValues: seed)
    }

    public func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        leaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) throws -> ShardAdmissionLease {
        guard key.capacityProfileID == capacityProfile.id else {
            throw V2ShardAdmissionLeaseControlError.capacityProfileDoesNotMatchPool
        }
        guard validUntil > now else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        guard pools[key] == nil else { throw V2ShardAdmissionLeaseControlError.poolAlreadyExists }

        let lease = try makeLease(
            id: leaseID,
            generation: 1,
            validUntil: validUntil,
            profile: capacityProfile.limits
        )
        pools[key] = try .init(lease: lease, outstandingFanoutUnits: 0, outstandingPlans: 0)
        return lease
    }

    public func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        validUntil: Date,
        now: Date
    ) throws -> ShardAdmissionLease {
        guard var state = pools[key], let current = state.lease else {
            throw V2ShardAdmissionLeaseControlError.poolNotFound
        }
        guard current.v2Fence == expectedFence else {
            throw V2ShardAdmissionLeaseControlError.fenceMismatch
        }
        guard current.isValid(at: now) else { throw V2ShardAdmissionLeaseControlError.leaseExpired }
        guard validUntil > current.validUntil else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }

        let renewed = try ShardAdmissionLease(
            id: current.id,
            generation: current.generation,
            validUntil: validUntil,
            commandWindow: current.commandWindow,
            fanoutWindow: current.fanoutWindow,
            maxOutstandingFanoutUnits: current.maxOutstandingFanoutUnits,
            maxOutstandingPlans: current.maxOutstandingPlans
        )
        state = try .init(
            lease: renewed,
            outstandingFanoutUnits: state.outstandingFanoutUnits,
            outstandingPlans: state.outstandingPlans
        )
        pools[key] = state
        return renewed
    }

    public func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        replacementLeaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) throws -> ShardAdmissionLease {
        guard key.capacityProfileID == capacityProfile.id else {
            throw V2ShardAdmissionLeaseControlError.capacityProfileDoesNotMatchPool
        }
        guard validUntil > now else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        guard let state = pools[key], let current = state.lease else {
            throw V2ShardAdmissionLeaseControlError.poolNotFound
        }
        guard !current.isValid(at: now) else {
            throw V2ShardAdmissionLeaseControlError.replacementRequiresExpiredLease
        }
        guard v2ShardLeaseMatchesProfile(current, capacityProfile.limits) else {
            throw V2ShardAdmissionLeaseControlError.capacityProfileLimitsChanged
        }
        guard current.generation < UInt64.max else {
            throw V2ShardAdmissionLeaseControlError.generationOverflow
        }

        let replacement = try makeLease(
            id: replacementLeaseID,
            generation: current.generation + 1,
            validUntil: validUntil,
            profile: capacityProfile.limits
        )
        pools[key] = try .init(
            lease: replacement,
            outstandingFanoutUnits: state.outstandingFanoutUnits,
            outstandingPlans: state.outstandingPlans
        )
        return replacement
    }

    public func state(for key: V2ShardAdmissionPoolKey) -> ShardAdmissionState? {
        pools[key]
    }

    private func makeLease(
        id: ShardAdmissionLeaseID,
        generation: UInt64,
        validUntil: Date,
        profile: RoomCapacityProfile
    ) throws -> ShardAdmissionLease {
        try .init(
            id: id,
            generation: generation,
            validUntil: validUntil,
            commandWindow: .init(limit: profile.maxCommandsPerWindow),
            fanoutWindow: .init(limit: profile.maxFanoutUnitsPerWindow),
            maxOutstandingFanoutUnits: profile.maxOutstandingFanoutUnits,
            maxOutstandingPlans: profile.maxOutstandingPlans
        )
    }
}
