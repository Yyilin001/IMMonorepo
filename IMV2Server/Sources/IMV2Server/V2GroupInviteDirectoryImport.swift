import Foundation

/// 导入房间邀请公共目录的一页数据。
public struct V2GroupInviteDirectoryImportCommand: Equatable, Sendable {
    /// 本次导入的幂等操作标识。
    public let operationID: UUID
    /// 目标逻辑分片。
    public let shardID: String
    /// 期望的归属代次。
    public let ownerEpoch: Int64
    /// 目标房间。
    public let roomID: UUID
    /// 分页游标，表示从该邀请之后继续；为空表示从头开始。
    public let afterInviteID: UUID?
    /// 本页最多导入的条数。
    public let limit: Int
    /// 运维重放原因。
    public let reason: V2DurableWorkReplayReason

    /// 校验并保存导入命令。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - shardID: 逻辑分片标识，需非空、不超过 128 字节且不含首尾空白。
    ///   - ownerEpoch: 非负的归属代次。
    ///   - roomID: 目标房间。
    ///   - afterInviteID: 分页游标，可为空。
    ///   - limit: 本页条数，需落在 `1...100`。
    ///   - reason: 重放原因。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupInviteDirectoryImportError/invalidRequest``。
    public init(operationID: UUID, shardID: String, ownerEpoch: Int64, roomID: UUID,
                afterInviteID: UUID?, limit: Int, reason: V2DurableWorkReplayReason) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines),
              ownerEpoch >= 0, (1...100).contains(limit)
        else { throw V2GroupInviteDirectoryImportError.invalidRequest }
        self.operationID = operationID; self.shardID = shardID; self.ownerEpoch = ownerEpoch
        self.roomID = roomID; self.afterInviteID = afterInviteID; self.limit = limit; self.reason = reason
    }
}

/// 单页导入的结果分类。
public enum V2GroupInviteDirectoryImportOutcome: String, Codable, Sendable { case applied, conflict }

/// 单页导入的统计结果。
public struct V2GroupInviteDirectoryImportResult: Equatable, Codable, Sendable {
    /// 本次导入的幂等操作标识。
    public let operationID: UUID
    /// 本次导入的结果分类。
    public let outcome: V2GroupInviteDirectoryImportOutcome
    /// 源数据中本页处理的条数。
    public let sourceCount: Int
    /// 新写入的条数。
    public let insertedCount: Int
    /// 本次对外发布的条数。
    public let publishedCount: Int
    /// 与已有记录一致、无需变更的条数。
    public let unchangedCount: Int
    /// 下一页游标；为空表示本页已到末尾。
    public let nextCursor: UUID?
    /// 与其他数据冲突的邀请标识。
    public let conflictingInviteIDs: [UUID]
    /// 本次调用是否命中已有的幂等结果。
    public let wasIdempotent: Bool

    /// 保存导入统计结果，不做取值校验。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - outcome: 结果分类。
    ///   - sourceCount: 本页源数据条数。
    ///   - insertedCount: 新写入条数。
    ///   - publishedCount: 发布条数。
    ///   - unchangedCount: 未变更条数。
    ///   - nextCursor: 下一页游标。
    ///   - conflictingInviteIDs: 冲突的邀请标识。
    ///   - wasIdempotent: 是否命中已有幂等结果。
    public init(operationID: UUID, outcome: V2GroupInviteDirectoryImportOutcome, sourceCount: Int,
                insertedCount: Int, publishedCount: Int, unchangedCount: Int, nextCursor: UUID?,
                conflictingInviteIDs: [UUID], wasIdempotent: Bool) {
        self.operationID = operationID; self.outcome = outcome; self.sourceCount = sourceCount
        self.insertedCount = insertedCount; self.publishedCount = publishedCount; self.unchangedCount = unchangedCount
        self.nextCursor = nextCursor; self.conflictingInviteIDs = conflictingInviteIDs; self.wasIdempotent = wasIdempotent
    }
}

/// 房间邀请公共目录导入错误。
public enum V2GroupInviteDirectoryImportError: Error, Equatable, Sendable {
    /// 命令参数不满足约束。
    case invalidRequest
    /// 请求的分片不在当前部署配置中。
    case unknownShard
    /// 目标房间归属已变更。
    case ownerChanged
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 房间邀请公共目录的导入能力。
///
/// 运维主体在构造时固定，绝不接受来自 HTTP 输入的取值。
public protocol V2GroupInviteDirectoryImporting: Sendable {
    /// 导入一页邀请数据。
    ///
    /// - Parameter command: 已校验的导入命令。
    /// - Returns: 本页导入统计。
    /// - Throws: 归属变化、幂等冲突或持久化失败时抛出。
    func importPage(_ command: V2GroupInviteDirectoryImportCommand) async throws -> V2GroupInviteDirectoryImportResult
}
