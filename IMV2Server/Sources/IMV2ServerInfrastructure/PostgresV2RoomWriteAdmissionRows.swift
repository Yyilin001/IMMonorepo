import IMV2ServerApplication
import IMV2ServerContracts
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
        try .init(lease: .init(id: ShardAdmissionLeaseID(uuid: leaseID), generation: try v2PersistenceUnsigned(generation, invalid: V2RoomWriteStoreError.corruptPersistenceState), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)))
    }
}
