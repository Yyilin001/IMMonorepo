import Foundation

/// 可清理的非权威记账与投影效果保留下限。
/// 永久操作证明不受此窗口约束；客户端首次提交期限由各领域合同声明。
public enum V2IdempotencyPolicy: Sendable {
    /// 非权威服务端记账最短保留时间：35 天，单位秒。
    public static let minimumServerRetention: TimeInterval = 35 * 86_400
}
