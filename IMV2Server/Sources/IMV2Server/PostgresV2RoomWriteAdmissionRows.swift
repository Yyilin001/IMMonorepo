import Foundation
import IMV2Core

// 解码逐条与批量接受路径使用的已加锁房间及准入快照。
// 事务和加锁顺序仍由 Store 选择。
struct RoomRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    /// 权威副本形态。群聊以它为准；单聊由部署开关决定，忽略本列。
    let frozenAt: Date?
    enum CodingKeys: String, CodingKey { case kind = "room_kind", roomShardID = "room_shard_id", roomSequence = "room_sequence", timelineSequence = "timeline_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class", frozenAt = "frozen_at" }

    func commandState(roomID: RoomID, admission: AdmissionRow) throws -> V2RoomCommandState {
        try .init(
            roomID: roomID,
            nextRoomSequence: roomWriteNextSequence(roomSequence),
            admission: admission.roomAdmissionState()
        )
    }

    /// 推进序号。
    ///
    /// 同一次原子追加中的每个同房间成员都看到预检的持久游标。
    /// 批次所有者会为后续成员分配连续的游标，
    /// 然后由那一次集合式追加把房间行改到最终值。
    /// 宁可拒绝溢出，也不让一个可观测的房间序号回绕。
    ///
    /// - Parameter offset: 需要推进的偏移量。
    /// - Returns: 推进后的写入集合。
    /// - Throws: 偏移为负或序号溢出时抛出。
    func advancingSequences(by offset: Int64) throws -> Self {
        guard offset >= 0,
              roomSequence <= Int64.max - offset,
              timelineSequence <= Int64.max - offset
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence + offset,
            timelineSequence: timelineSequence + offset,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }
}

struct AdmissionSnapshotRow: Decodable {
    let roomEligibleMemberCount: Int
    let roomCommandWindowLimit: Int
    let roomCommandWindowUsed: Int
                            let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shardLeaseID: UUID
    let shardGeneration: Int64
    let shardValidUntil: Date
    let shardCommandWindowLimit: Int
    let shardCommandWindowUsed: Int
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?

    var room: AdmissionRow {
        .init(
            eligibleMemberCount: roomEligibleMemberCount,
            commandWindowLimit: roomCommandWindowLimit,
            commandWindowUsed: roomCommandWindowUsed,

            shardLeaseID: roomShardLeaseID,
            shardLeaseGeneration: roomShardLeaseGeneration
        )
    }

    var shard: ShardRow {
        .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed)
    }

    enum CodingKeys: String, CodingKey {
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"

        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
    }
}

struct AdmissionRow: Decodable {
    let eligibleMemberCount: Int
    let commandWindowLimit: Int
    let commandWindowUsed: Int
                            let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey {
        case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation"
    }
    func roomAdmissionState() throws -> RoomAdmissionState {
        try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))
    }
}

struct ShardRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
                            enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used"
    }
    func admissionState() throws -> ShardAdmissionState {
        try .init(lease: .init(id: ShardAdmissionLeaseID(uuid: leaseID), generation: try admissionRowUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)))
    }
}

private func admissionRowUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
