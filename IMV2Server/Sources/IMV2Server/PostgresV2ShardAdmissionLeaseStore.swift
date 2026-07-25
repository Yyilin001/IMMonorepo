import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL control-plane store for fenced shard admission leases.
///
/// Every mutation locks the pool row. Replacement changes both lease ID and
/// generation only after expiry; the schema's `ON UPDATE CASCADE` keeps every
/// room admission row on the new fence in the same transaction.
public struct PostgresV2ShardAdmissionLeaseStore: V2ShardAdmissionLeaseStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        leaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease {
        try ensureProfile(capacityProfile, matches: key)
        guard validUntil > now else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let existing = try await selectPool(key: key, sql: sql)
            guard existing == nil else { throw V2ShardAdmissionLeaseControlError.poolAlreadyExists }

            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans)
                VALUES
                    (\(bind: key.roomShardID), \(bind: key.capacityProfileID), \(bind: try uuid(leaseID)), 1, \(bind: validUntil),
                     \(bind: capacityProfile.limits.maxCommandsPerWindow), \(bind: capacityProfile.limits.maxFanoutUnitsPerWindow),
                     \(bind: capacityProfile.limits.maxOutstandingFanoutUnits), \(bind: capacityProfile.limits.maxOutstandingPlans))
                """).run()
            return try ShardAdmissionLease(
                id: leaseID,
                generation: 1,
                validUntil: validUntil,
                commandWindow: .init(limit: capacityProfile.limits.maxCommandsPerWindow),
                fanoutWindow: .init(limit: capacityProfile.limits.maxFanoutUnitsPerWindow),
                maxOutstandingFanoutUnits: capacityProfile.limits.maxOutstandingFanoutUnits,
                maxOutstandingPlans: capacityProfile.limits.maxOutstandingPlans
            )
        }
    }

    public func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let current = try await selectPool(key: key, sql: sql) else {
                throw V2ShardAdmissionLeaseControlError.poolNotFound
            }
            let expectedLeaseID = try uuid(expectedFence.id)
            let expectedGeneration = try signed(expectedFence.generation)
            guard current.leaseID == expectedLeaseID, current.generation == expectedGeneration else {
                throw V2ShardAdmissionLeaseControlError.fenceMismatch
            }
            guard current.validUntil > now else { throw V2ShardAdmissionLeaseControlError.leaseExpired }
            guard validUntil > current.validUntil else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }

            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET valid_until = \(bind: validUntil)
                WHERE room_shard_id = \(bind: key.roomShardID)
                  AND capacity_profile_id = \(bind: key.capacityProfileID)
                  AND lease_id = \(bind: current.leaseID)
                  AND generation = \(bind: current.generation)
                """).run()
            return try current.lease(validUntil: validUntil)
        }
    }

    public func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        replacementLeaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease {
        try ensureProfile(capacityProfile, matches: key)
        guard validUntil > now else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let current = try await selectPool(key: key, sql: sql) else {
                throw V2ShardAdmissionLeaseControlError.poolNotFound
            }
            guard current.validUntil <= now else {
                throw V2ShardAdmissionLeaseControlError.replacementRequiresExpiredLease
            }
            guard current.matches(capacityProfile.limits) else {
                throw V2ShardAdmissionLeaseControlError.capacityProfileLimitsChanged
            }
            guard current.generation < Int64.max else {
                throw V2ShardAdmissionLeaseControlError.generationOverflow
            }

            let replacementID = try uuid(replacementLeaseID)
            let replacementGeneration = current.generation + 1
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET lease_id = \(bind: replacementID),
                    generation = \(bind: replacementGeneration),
                    valid_until = \(bind: validUntil),
                    command_window_used = 0,
                    fanout_window_used = 0
                WHERE room_shard_id = \(bind: key.roomShardID)
                  AND capacity_profile_id = \(bind: key.capacityProfileID)
                  AND lease_id = \(bind: current.leaseID)
                  AND generation = \(bind: current.generation)
                """).run()
            return try current.lease(
                id: replacementLeaseID,
                generation: replacementGeneration,
                validUntil: validUntil,
                resetWindows: true
            )
        }
    }

    private func ensureProfile(_ profile: V2CapacityProfile, matches key: V2ShardAdmissionPoolKey) throws {
        guard profile.id == key.capacityProfileID else {
            throw V2ShardAdmissionLeaseControlError.capacityProfileDoesNotMatchPool
        }
    }

    private func selectPool(key: V2ShardAdmissionPoolKey, sql: any SQLDatabase) async throws -> V2ShardAdmissionPoolRow? {
        try await sql.raw("""
            SELECT lease_id, generation, valid_until, command_window_limit, command_window_used,
                   fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                   outstanding_fanout_units, max_outstanding_plans, outstanding_plans
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: key.roomShardID)
              AND capacity_profile_id = \(bind: key.capacityProfileID)
            FOR UPDATE
            """).first(decoding: V2ShardAdmissionPoolRow.self)
    }
}

private struct V2ShardAdmissionPoolRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", generation, validUntil = "valid_until"
        case commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used"
        case fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used"
        case maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units"
        case maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans"
    }

    func matches(_ profile: RoomCapacityProfile) -> Bool {
        commandWindowLimit == profile.maxCommandsPerWindow
            && fanoutWindowLimit == profile.maxFanoutUnitsPerWindow
            && maxOutstandingFanoutUnits == profile.maxOutstandingFanoutUnits
            && maxOutstandingPlans == profile.maxOutstandingPlans
    }

    func lease(
        id: ShardAdmissionLeaseID? = nil,
        generation: Int64? = nil,
        validUntil: Date? = nil,
        resetWindows: Bool = false
    ) throws -> ShardAdmissionLease {
        try .init(
            id: id ?? .init(leaseID.uuidString),
            generation: try unsigned(generation ?? self.generation),
            validUntil: validUntil ?? self.validUntil,
            commandWindow: .init(limit: commandWindowLimit, used: resetWindows ? 0 : commandWindowUsed),
            fanoutWindow: .init(limit: fanoutWindowLimit, used: resetWindows ? 0 : fanoutWindowUsed),
            maxOutstandingFanoutUnits: maxOutstandingFanoutUnits,
            maxOutstandingPlans: maxOutstandingPlans
        )
    }
}

private func uuid(_ value: ShardAdmissionLeaseID) throws -> UUID {
    guard let parsed = UUID(uuidString: value.rawValue) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return parsed
}

private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return Int64(value)
}

private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
