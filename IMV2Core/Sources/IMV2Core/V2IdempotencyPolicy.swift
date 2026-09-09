import Foundation

/// 客户端与服务端共享的有限幂等重试窗口约定。
///
/// 客户端先停止自动重放，服务端保留更长结果窗口，为时钟偏差、维护延迟及已在途尝试留出余量。常量本身不执行清理或去重，调用路径必须落实该约定。
public enum V2IdempotencyPolicy: Sendable {
    /// 客户端命令允许自动重试的最大年龄：30 天，单位秒。
    public static let maximumClientRetryAge: TimeInterval = 30 * 86_400
    /// 服务端幂等结果最短保留时间：35 天，单位秒。
    public static let minimumServerRetention: TimeInterval = 35 * 86_400
    /// 客户端命令超过重试窗口时使用的稳定错误码 IDEMPOTENCY_WINDOW_EXPIRED。
    public static let expiredClientCommandCode = "IDEMPOTENCY_WINDOW_EXPIRED"
}
