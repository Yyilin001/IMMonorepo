import IMV2ServerApplication
import IMV2ServerContracts
import Synchronization

/// 每次事务尝试使用一份日志，而非每条命令一份。
/// Database.transaction 自身成功返回前，不将任何内容标记为已提交。
final class V2RoomTransactionAttempt: Sendable {
    private let returnedToDriver = Mutex(false)

    func body<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let value = try await operation()
        returnedToDriver.withLock { $0 = true }
        return value
    }

    func classify(_ error: any Error) -> any Error {
        // PostgreSQL 的死锁或序列化错误可证明事务已中止，
        // 包括 COMMIT 阶段才出现的延迟失败。
        // 其他提交阶段错误即使诊断文本看似可重试，结果仍不确定。
        if returnedToDriver.withLock({ $0 }),
           v2PostgresFailureDisposition(error) != .retryTransaction {
            return V2RoomTransactionOutcomeUnknown()
        }
        return error
    }
}
