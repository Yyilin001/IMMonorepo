import Foundation
import IMV2Core

package enum V2MessageProjectionStateError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidTransition
}

// 不可变投影格式使用向下取整，1970 年之前的时间也一样。
// SQL 事件写入器共用此转换，避免载荷与类型化投影不一致，
// 从而错误触发不可变内容栅栏。
/// 计算已接受消息的投影毫秒时间戳。
///
/// 优先使用消息自带的投影时间戳，缺失时回落到创建时刻。
///
/// - Parameter message: 已接受消息。
/// - Returns: 投影使用的 Unix 毫秒时间戳。
/// - Throws: 时刻无法表示为毫秒整数时抛出
///   ``V2MessageProjectionStateError/invalidPayload``。
package func v2MessageProjectionMilliseconds(_ message: V2AcceptedMessage) throws -> Int64 {
    let dateMilliseconds = try v2MessageProjectionMilliseconds(message.createdAt)
    return message.projectionCreatedAtUnixMilliseconds ?? dateMilliseconds
}

/// 以向下取整方式把时刻转换为 Unix 毫秒。
///
/// 不可变投影格式统一使用向下取整，包括 1970 年之前的时间；SQL 事件写入方共用同一转换，
/// 使其载荷不会与强类型投影产生分歧并误判为内容栅栏不通过。
///
/// - Parameter date: 待转换时刻。
/// - Returns: Unix 毫秒时间戳。
/// - Throws: 取值超出 `Int64` 范围时抛出
///   ``V2MessageProjectionStateError/invalidPayload``。
package func v2MessageProjectionMilliseconds(_ date: Date) throws -> Int64 {
    guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.down)) else {
        throw V2MessageProjectionStateError.invalidPayload
    }
    return value
}
