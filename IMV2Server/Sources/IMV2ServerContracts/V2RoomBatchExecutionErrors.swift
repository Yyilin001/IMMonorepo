import Foundation

/// 事务主体成功返回，但驱动未确认 COMMIT。
/// 调用方不能继续轮次，需要恢复已提交的结果。
package struct V2RoomTransactionOutcomeUnknown: Error, Sendable {
    package init() {}
}
