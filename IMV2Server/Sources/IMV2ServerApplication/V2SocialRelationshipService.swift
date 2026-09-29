import IMV2ServerContracts
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
