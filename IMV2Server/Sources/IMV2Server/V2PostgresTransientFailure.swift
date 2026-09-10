import AsyncKit
import Fluent
import Foundation
import PostgresNIO

/// 数据库失败的处置分类。
enum V2PostgresFailureDisposition: Equatable, Sendable {
    /// 事务被回滚，可整体重试。
    case retryTransaction
    /// 依赖不可用，应作为临时不可用上报。
    case unavailable
    /// 其他错误，按原样抛出。
    case other
}

/// 把数据库驱动细节限制在 PostgreSQL 边界内。
///
/// 只有已知的瞬时失败会被归类为可重试或不可用；编程错误与约束冲突仍按原样向调用方抛出，
/// 不会被误判成可以重试的临时故障。
///
/// - Parameter error: 待分类的错误。
/// - Returns: 该错误对应的处置分类。
func v2PostgresFailureDisposition(_ error: any Error) -> V2PostgresFailureDisposition {
    if error is ConnectionPoolTimeoutError || error is ConnectionPoolError {
        return .unavailable
    }
    if let error = error as? PSQLError {
        if let state = error.serverInfo?[.sqlState] {
            return v2PostgresFailureDisposition(sqlState: state)
        }
        switch error.code {
        case .queryCancelled,
             .clientClosedConnection,
             .serverClosedConnection,
             .connectionError,
             .uncleanShutdown,
             .poolClosed:
            return .unavailable
        default:
            return .other
        }
    }
    if let error = error as? PostgresError {
        switch error {
        case .server(let message):
            guard let state = message.fields[.sqlState] else { return .other }
            return v2PostgresFailureDisposition(sqlState: state)
        case .connectionClosed:
            return .unavailable
        case .protocol:
            return .other
        }
    }
    return .other
}

/// 按 SQLSTATE 分类服务端错误。
///
/// - Parameter sqlState: PostgreSQL 五位状态码。
/// - Returns: 死锁与序列化失败归类为可重试；锁超时、语句取消、服务关闭，
///   以及 `08`、`53` 前缀的连接与资源类错误归类为不可用；其余为其他错误。
private func v2PostgresFailureDisposition(sqlState: String) -> V2PostgresFailureDisposition {
    switch sqlState {
    case "40P01", "40001":
        return .retryTransaction
    case "55P03", "57014", "57P01", "57P02", "57P03":
        return .unavailable
    default:
        if sqlState.hasPrefix("08") || sqlState.hasPrefix("53") {
            return .unavailable
        }
        return .other
    }
}

/// 在 PostgreSQL 因死锁或序列化失败回滚后重试整个事务。
///
/// 在已中止的事务内重试单条语句是无效的，因此调用方必须把完整的幂等命令放进本边界；
/// 重试之间会做短随机退避，避免相向请求立刻重建同一条等待图。
///
/// - Parameters:
///   - database: 执行事务的数据库。
///   - maximumRetryCount: 最大额外重试次数，默认 2，需非负。
///   - operation: 事务内执行的幂等操作。
/// - Returns: 操作结果。
/// - Throws: 任务取消时抛出 `CancellationError`；其他错误在重试耗尽后按原样抛出。
func v2WithPostgresTransactionRetry<Result: Sendable>(
    database: any Database,
    maximumRetryCount: Int = 2,
    _ operation: @escaping @Sendable (any Database) async throws -> Result
) async throws -> Result {
    precondition(maximumRetryCount >= 0)
    var retryCount = 0
    while true {
        try Task.checkCancellation()
        do {
            return try await database.transaction(operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard v2PostgresFailureDisposition(error) == .retryTransaction,
                  retryCount < maximumRetryCount
            else { throw error }
            retryCount += 1
            // Short randomized backoff prevents opposing requests from
            // immediately rebuilding the same wait-for graph.
            let lowerNanoseconds = UInt64(retryCount) * 2_000_000
            let upperNanoseconds = UInt64(retryCount) * 8_000_000
            try await Task.sleep(
                nanoseconds: UInt64.random(in: lowerNanoseconds ... upperNanoseconds)
            )
        }
    }
}
