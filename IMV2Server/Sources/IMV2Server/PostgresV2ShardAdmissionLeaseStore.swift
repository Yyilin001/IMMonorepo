import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 带栅栏的分片准入租约在 PostgreSQL 上的控制面存储。
///
/// 每次变更都会锁定准入池行。只有在原租约确已过期后，替换才会同时更新租约标识与代次；
/// schema 上的 `ON UPDATE CASCADE` 会在同一事务内把全部房间准入行切到新栅栏。
public struct PostgresV2ShardAdmissionLeaseStore: V2ShardAdmissionLeaseStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放分片准入池的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 为一个新的准入池签发租约。
    ///
    /// 会先确认容量档位与准入池身份一致、到期时刻晚于当前时刻，再在同一事务内
    /// 确认准入池尚不存在并插入租约与各项上限。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 本次使用的容量档位。
    ///   - leaseID: 新租约标识。
    ///   - validUntil: 租约到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 已签发的租约。
    /// - Throws: 档位标识与准入池不一致时抛出
    ///   ``V2ShardAdmissionLeaseControlError/capacityProfileDoesNotMatchPool``；
    ///   到期时刻不晚于当前时刻时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidLifetime``；准入池已存在时抛出
    ///   ``V2ShardAdmissionLeaseControlError/poolAlreadyExists``。
    public func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        leaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease {
        try ensureProfile(capacityProfile, matches: key)
        guard v2PostgresTimestampPrecedes(now, validUntil) else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let existing = try await selectPool(key: key, sql: sql)
            guard existing == nil else { throw V2ShardAdmissionLeaseControlError.poolAlreadyExists }

            guard try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
                     command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans)
                VALUES
                    (\(bind: key.roomShardID), \(bind: key.capacityProfileID), \(bind: try uuid(leaseID)), 1, \(bind: validUntil),
                     \(bind: capacityProfile.limits.maxCommandsPerWindow), \(bind: capacityProfile.limits.maxFanoutUnitsPerWindow),
                     \(bind: capacityProfile.limits.maxOutstandingFanoutUnits), \(bind: capacityProfile.limits.maxOutstandingPlans))
                ON CONFLICT (room_shard_id, capacity_profile_id) DO NOTHING
                RETURNING 1
                """).first() != nil else {
                // SELECT FOR UPDATE cannot lock an absent row. A concurrent
                // initializer may create this pool after the lookup above.
                throw V2ShardAdmissionLeaseControlError.poolAlreadyExists
            }
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

    /// 按栅栏值续租。
    ///
    /// 只有租约标识与代次都与期望值一致且租约尚未过期时才会延期，
    /// 代次保持不变，因此续租不会使既有房间准入行失效。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - expectedFence: 期望的当前租约栅栏。
    ///   - validUntil: 新的到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 续租后的租约。
    /// - Throws: 准入池不存在时抛出 ``V2ShardAdmissionLeaseControlError/poolNotFound``；
    ///   栅栏不匹配时抛出 ``V2ShardAdmissionLeaseControlError/fenceMismatch``；
    ///   租约已过期时抛出 ``V2ShardAdmissionLeaseControlError/leaseExpired``。
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
            guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(validUntil) else {
                throw V2ShardAdmissionLeaseControlError.invalidLifetime
            }
            guard v2PostgresTimestampCanEncode(current.validUntil) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard current.validUntil > now else { throw V2ShardAdmissionLeaseControlError.leaseExpired }
            guard v2PostgresTimestampPrecedes(current.validUntil, validUntil) else {
                throw V2ShardAdmissionLeaseControlError.invalidLifetime
            }

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

    /// 在原租约确已过期后签发替代租约。
    ///
    /// 替换会同时更新租约标识与代次，代次溢出或原租约尚未过期时拒绝执行；
    /// 级联更新使全部房间准入行在同一事务内切到新栅栏。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 替代租约使用的容量档位。
    ///   - replacementLeaseID: 替代租约标识。
    ///   - validUntil: 替代租约到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 替代租约。
    /// - Throws: 准入池不存在时抛出 ``V2ShardAdmissionLeaseControlError/poolNotFound``；
    ///   档位上限已被改写时抛出
    ///   ``V2ShardAdmissionLeaseControlError/capacityProfileLimitsChanged``；
    ///   原租约尚未过期时抛出
    ///   ``V2ShardAdmissionLeaseControlError/replacementRequiresExpiredLease``；
    ///   代次溢出时抛出 ``V2ShardAdmissionLeaseControlError/generationOverflow``。
    public func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        replacementLeaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease {
        try ensureProfile(capacityProfile, matches: key)
        guard v2PostgresTimestampPrecedes(now, validUntil) else { throw V2ShardAdmissionLeaseControlError.invalidLifetime }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let current = try await selectPool(key: key, sql: sql) else {
                throw V2ShardAdmissionLeaseControlError.poolNotFound
            }
            guard v2PostgresTimestampCanEncode(current.validUntil) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
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
