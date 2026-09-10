import Foundation

/// 网关响应或通知的日期无法表示为协议要求的有符号毫秒时间戳时产生的错误。
enum V2GatewayTimestampError: Error {
    /// 日期为非有限值，或转换并截断后的毫秒数超出 `Int64` 范围。
    case unrepresentable
}

/// 将服务端日期转换为网关协议中的 Unix 毫秒时间戳。
///
/// 在编码响应或通知前拒绝非有限日期和整数溢出，避免直接整数转换触发运行时失败。
/// 转换沿用协议的向零截断规则：不足一毫秒的部分被舍弃，纪元之前的日期可返回负数。
/// 此方法只检查协议表示范围，不验证业务上的有效期或 PostgreSQL 时间戳范围。
///
/// - Parameter date: 待编码的绝对日期，以 1970-01-01 UTC 为毫秒偏移起点。
/// - Returns: 向零截断后可由 `Int64` 表示的毫秒数。
/// - Throws: 无法表示时抛出 `V2GatewayTimestampError.unrepresentable`。
func v2GatewayMilliseconds(_ date: Date) throws -> Int64 {
    guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
        throw V2GatewayTimestampError.unrepresentable
    }
    return value
}
