import Foundation

/// 计算严格晚于当前时间的有限重试日期。
///
/// - Parameters:
///   - now: 用于持久化调度的当前墙上时钟。
///   - delay: 正且有限的延迟秒数。
/// - Returns: 加法后仍有限且严格增加的日期。
/// - Throws: 基准、延迟或结果无效，或延迟因日期精度丢失而未推进时间时，抛出无效重试日期错误。
///
/// 避免调度器持续读到同一个已到期命令而忙循环。本方法不提供单调时钟，也不检查具体数据库的时间编码范围。
func v2CommandRetryDate(now: Date, delay: TimeInterval) throws -> Date {
    let deadline = now.addingTimeInterval(delay)
    guard now.timeIntervalSince1970.isFinite, delay.isFinite, delay > 0,
          deadline.timeIntervalSince1970.isFinite, deadline > now else {
        throw V2CommandRetrySchedulerError.invalidDate
    }
    return deadline
}
