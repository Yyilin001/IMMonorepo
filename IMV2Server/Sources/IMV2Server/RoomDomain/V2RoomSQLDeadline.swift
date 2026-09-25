import FluentKit
import Foundation

/// 在领域层间传递获准调用的绝对 SQL 时间预算。
/// 它只属于调度上下文，绝不提供或替代激活令牌、所有者围栏或授权决定。
enum V2RoomSQLDeadline {
    @TaskLocal static var current: ContinuousClock.Instant?
    static let maximumTransactionDuration: Duration = .seconds(10)

    static func boundedTransactionDeadline() -> ContinuousClock.Instant {
        let limit = ContinuousClock.now + maximumTransactionDuration
        return current.map { min($0, limit) } ?? limit
    }

    nonisolated(nonsending) static func withDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let selected = current.map { min($0, deadline) } ?? deadline
        return try await $current.withValue(selected, operation: operation)
    }

    /// 批处理器从多个调用方选取工作，须将继承的任务上下文
    /// 替换为本次选取中最早的截止时间。
    nonisolated(nonsending) static func withSelectedDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        try await $current.withValue(deadline, operation: operation)
    }
}

/// 仅房间范围内的调用点启用此机制。直接按令牌调用存储时使用固定的十秒预算；
/// 已获准调用使用更早的宿主截止时间。旧控制侧调用保留 Fluent 事务实现。
func v2WithRoomScopedTransaction<Value: Sendable>(
    database: any Database,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    useRoomDeadline: Bool = true,
    _ operation: @escaping @Sendable (any Database) async throws -> Value
) async throws -> Value {
    if useRoomDeadline {
        return try await v2WithRoomActivationTransaction(
            database: database, deadline: V2RoomSQLDeadline.boundedTransactionDeadline(),
            timeouts: timeouts, operation)
    }
    return try await database.transaction(operation)
}
