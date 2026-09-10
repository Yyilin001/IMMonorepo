import Foundation
import IMV2Core

/// 社交关系变更结果。
public enum V2RelationshipOutcome: Equatable, Sendable {
    /// 本次调用实际提交了关系变更。
    case changed(V2RelationshipChange)
    /// 同一操作标识已提交过等价变更，返回其原有结果。
    case idempotent(V2RelationshipChange)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 命令与当前关系状态不兼容，无法应用。
    case invalidState
    /// 拉黑被刻意呈现为通用授权失败；调用方不应得知是哪一方发起了拉黑。
    case forbidden
}

/// 用户拉黑变更结果。
public enum V2UserBlockOutcome: Equatable, Sendable {
    /// 本次调用实际提交了拉黑变更。
    case changed(V2UserBlockChange)
    /// 同一操作标识已提交过等价变更，返回其原有结果。
    case idempotent(V2UserBlockChange)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
}

/// 社交关系与拉黑的持久化能力。
public protocol V2SocialRelationshipStore: Sendable {
    /// 应用一次关系变更。
    ///
    /// - Parameters:
    ///   - command: 关系变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 关系变更结果。
    /// - Throws: 持久化失败或状态损坏时抛出。
    func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) async throws -> V2RelationshipOutcome

    /// 应用一次用户拉黑变更。
    ///
    /// - Parameters:
    ///   - command: 拉黑变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拉黑变更结果。
    /// - Throws: 持久化失败或状态损坏时抛出。
    func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) async throws -> V2UserBlockOutcome
}

/// 需认证的关系与拉黑命令边界。
///
/// 用户对锁、持久化幂等结果以及用户同步投影都由存储层负责，本服务只补齐授时。
public struct V2SocialRelationshipService: Sendable {
    private let store: any V2SocialRelationshipStore
    private let now: @Sendable () -> Date

    /// 组合社交关系存储与授时来源。
    ///
    /// - Parameters:
    ///   - store: 实际执行变更的存储实现。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2SocialRelationshipStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// 变更当前用户与目标用户之间的关系。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 关系变更的目标用户。
    ///   - action: 需要应用的关系动作。
    /// - Returns: 关系变更结果。
    /// - Throws: 命令构造失败或存储判定状态非法时抛出。
    public func changeRelationship(actorUserID: UserID, operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2RelationshipOutcome {
        try await store.changeRelationship(try .init(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID, action: action), now: now())
    }

    /// 变更当前用户对目标用户的拉黑状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 拉黑变更的目标用户。
    ///   - action: 需要应用的拉黑动作。
    /// - Returns: 拉黑变更结果。
    /// - Throws: 命令构造失败或存储判定状态非法时抛出。
    public func changeUserBlock(actorUserID: UserID, operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2UserBlockOutcome {
        try await store.changeUserBlock(try .init(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID, action: action), now: now())
    }
}
