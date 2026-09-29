import Foundation

/// 持久化工作的下一步处置。
public enum V2DurableRetryDisposition: Equatable, Sendable {
    /// 在指定时刻重试。
    case retry(at: Date)
    /// 暂停该行，等待运维重放。
    case pause
}

/// 持久化工作失败的类别，决定是否值得继续自动重试。
///
/// 判定必须保守：把瞬时失败误判为确定性只会暂停一行（与分类前的行为相同），
/// 而把确定性失败误判为瞬时会让该行持续重试，因此判定入口对无法证明是数据或
/// 不可变身份冲突的失败一律返回 ``transient``。
public enum V2DurableWorkFailureKind: Equatable, Sendable {
    /// 依赖或资源暂时不可用：根因恢复后同一工作仍可完成，必须继续重试。
    case transient
    /// 数据形状或不可变身份冲突：重复执行不会得到不同结果，必须暂停。
    case deterministic
}
