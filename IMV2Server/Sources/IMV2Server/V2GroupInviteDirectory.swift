import Foundation
import IMV2Core

/// 邀请定位记录。
///
/// 控制面只持有令牌定位与可重试的创建输入；房间授权、有效期、使用与审批决定
/// 仍然保存在当前归属侧。
public struct V2GroupInviteLocation: Equatable, Sendable {
    /// 邀请标识。
    public let inviteID: GroupInviteID
    /// 邀请所属房间。
    public let roomID: RoomID
}

/// 邀请创建意图。
public struct V2GroupInviteCreationIntent: Sendable {
    /// 已固定并可供归属侧写入的创建请求。
    public let request: V2GroupInviteCreatePersistenceRequest
    /// 归属侧是否已经完成持久化提交。
    public let isReady: Bool
}

/// 邀请目录错误。
public enum V2GroupInviteDirectoryError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 目录中已存在冲突的记录。
    case conflict
    /// 归属侧返回的记录与创建意图不一致。
    case ownerResultMismatch
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 邀请目录能力，负责在归属事务之外保存创建意图与令牌定位。
public protocol V2GroupInviteDirectory: Sendable {
    /// 准备邀请创建意图。
    ///
    /// 同一发起者、同一操作标识与相同业务输入的重试会返回原有的邀请标识与时间戳，
    /// 不受本次候选值变化影响。
    ///
    /// - Parameter request: 邀请创建持久化请求。
    /// - Returns: 稳定可重试的创建意图。
    /// - Throws: 请求非法或存在冲突时抛出。
    func prepare(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2GroupInviteCreationIntent

    /// 在归属侧持久化提交匹配邀请之后标记创建意图完成。
    ///
    /// - Parameters:
    ///   - intent: 已提交的创建意图。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func finalize(_ intent: V2GroupInviteCreationIntent, now: Date) async throws

    /// 按令牌摘要解析邀请定位。
    ///
    /// 仅准备好的创建意图对令牌预览与提交不可见，因此此处不会返回尚未定稿的邀请。
    ///
    /// - Parameter tokenDigest: 邀请令牌摘要。
    /// - Returns: 邀请定位；不存在时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func resolve(tokenDigest: Data) async throws -> V2GroupInviteLocation?

    /// 查询指定邀请中已经可用的项。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - inviteIDs: 候选邀请标识集合。
    /// - Returns: 结果中可用的邀请标识子集。
    /// - Throws: 持久化失败时抛出。
    func readyInvites(roomID: RoomID, inviteIDs: Set<GroupInviteID>) async throws -> Set<GroupInviteID>
}

/// 邀请创建协调器，负责先落意图、再调用归属、最后标记完成。
///
/// 数据库事务不会跨越归属调用：归属结果不确定时意图保持准备状态，
/// 重试沿用同一归属操作标识。归属回调必须自行解析房间当前路由，并在事务内校验代次；
/// 令牌目录中的记录永远不构成归属声明。
public struct V2GroupInviteCreationCoordinator: Sendable {
    private let directory: any V2GroupInviteDirectory

    /// 组合邀请目录。
    ///
    /// - Parameter directory: 保存创建意图与令牌定位的目录实现。
    public init(directory: any V2GroupInviteDirectory) { self.directory = directory }

    /// 创建邀请：先准备意图，再交由归属持久化，最后标记完成。
    ///
    /// 归属返回的记录必须在邀请标识、房间、发起者、操作标识、最大可用次数与时间戳上与
    /// 意图完全一致，任何偏差都视为归属结果不匹配而不做兼容处理。
    ///
    /// - Parameters:
    ///   - request: 邀请创建持久化请求。
    ///   - ownerCommit: 在归属侧持久化邀请的回调。
    /// - Returns: 归属侧返回的持久化邀请。
    /// - Throws: 归属结果与意图不一致时抛出
    ///   ``V2GroupInviteDirectoryError/ownerResultMismatch``；其余错误来自目录或归属回调。
    public func create(
        _ request: V2GroupInviteCreatePersistenceRequest,
        ownerCommit: @Sendable (V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite
    ) async throws -> V2StoredGroupInvite {
        let intent = try await directory.prepare(request)
        let stored = try await ownerCommit(intent.request)
        guard stored.inviteID == intent.request.inviteID,
              stored.roomID == intent.request.roomID,
              stored.createdByUserID == intent.request.actorUserID,
              stored.creationOperationID == intent.request.operationID,
              stored.maximumApprovedUses == intent.request.maximumApprovedUses,
              creationTimesMatch(stored, intent.request)
        else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        try await directory.finalize(intent, now: request.evaluatedAt)
        return stored
    }

    /// 比较归属记录与请求的时间戳是否一致。
    ///
    /// 双方都提供持久化时间戳时按精确值比较，避免 `Date` 的近似掩盖持久化层面的差异；
    /// 仅支持 `Date` 的存储适配器保留原有的微秒级容差。
    ///
    /// - Parameters:
    ///   - stored: 归属侧返回的持久化邀请。
    ///   - request: 创建请求。
    /// - Returns: 两者时间戳一致时为 `true`。
    private func creationTimesMatch(_ stored: V2StoredGroupInvite, _ request: V2GroupInviteCreatePersistenceRequest) -> Bool {
        // A database receipt must prove the exact immutable binding. Date's
        // approximation must not hide differences that persistence preserves.
        if let actual = stored.persistedTimestamps, let expected = request.persistedTimestamps {
            return actual == expected
        }
        // Retain the established tolerance for Date-only store adapters.
        return abs(stored.createdAt.timeIntervalSince(request.createdAt)) < 0.000002
            && abs(stored.expiresAt.timeIntervalSince(request.expiresAt)) < 0.000002
    }
}
