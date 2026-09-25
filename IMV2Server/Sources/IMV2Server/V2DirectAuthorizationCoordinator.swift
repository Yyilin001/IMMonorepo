import FluentKit
import Foundation

enum V2DirectAuthorizationCoordinationError: Error, Equatable, Sendable {
    case ownerUnavailable, revocationIncomplete, invalidLimit
}

public struct V2DirectAuthorizationRecoveryResult: Equatable, Sendable {
    public let claimed: Int
    public let resolved: Int
    public let deferred: Int
}

/// 持久化所有者中止或证明后，接着由控制侧确认。
/// 即使同址，控制连接池也必须独立于策略写入池和授权预留池：
/// 预留可能占用连接，等待由策略写入方持有的锁，
/// 而该写入方又需要确认所有者证明。
/// 策略写入方在修改前调用 drain；运行时组合和恢复生命周期登记仍不可缺少。
public struct V2DirectAuthorizationCoordinator: Sendable {
    private let intents: PostgresV2DirectAuthorizationIntentStore
    private let ownerAbort: @Sendable (V2DirectAuthorizationAttempt, Date) async throws -> V2DirectAuthorizationReceipt

    public init(controlDatabase: any Database, ownerDatabases: [String: any Database]) {
        self.intents = .init(database: controlDatabase)
        self.ownerAbort = { attempt, now in
            guard let database = ownerDatabases[attempt.ownerShardID] else {
                throw V2DirectAuthorizationCoordinationError.ownerUnavailable
            }
            return try await PostgresV2DirectAuthorizationReceiptStore().abort(attempt, now: now, database: database)
        }
    }

    init(intents: PostgresV2DirectAuthorizationIntentStore,
         ownerAbort: @escaping @Sendable (V2DirectAuthorizationAttempt, Date) async throws -> V2DirectAuthorizationReceipt) {
        self.intents = intents; self.ownerAbort = ownerAbort
    }

    /// 在策略的控制侧独占锁下、修改策略前调用。
    /// 每份证明都在独立控制连接上确认，因此回滚或所有者不可用
    /// 不会抹掉已完成的排空进度。大队列只推进有界部分并要求重试，
    /// 绝不伪装成成功。
    func drain(_ scope: V2DirectAuthorizationRevocationScope, transaction: any Database, now: Date, limit: Int = 128) async throws {
        guard (1...128).contains(limit) else { throw V2DirectAuthorizationCoordinationError.invalidLimit }
        try Task.checkCancellation()
        let pending = try await intents.held(in: scope, limit: limit, transaction: transaction)
        for grant in pending {
            try Task.checkCancellation()
            let receipt = try await ownerAbort(grant.attempt, now)
            guard try await intents.resolve(grant.attempt, receipt: receipt, now: now) else {
                throw V2DirectAuthorizationCoordinationError.revocationIncomplete
            }
        }
        guard try await intents.held(in: scope, limit: 1, transaction: transaction).isEmpty else {
            throw V2DirectAuthorizationCoordinationError.revocationIncomplete
        }
    }

    /// 到期任务可取消其精确代次，即使原调用方仍在运行；
    /// 所有者锁与墓碑使取消结果持久化。
    /// 所有者不可用只会延后任务，绝不释放授权许可。
    public func recover(limit: Int, now: Date) async throws -> V2DirectAuthorizationRecoveryResult {
        try Task.checkCancellation()
        let claimed = try await intents.claim(limit: limit, now: now)
        var resolved = 0, deferred = 0
        for grant in claimed {
            do {
                try Task.checkCancellation()
                let receipt = try await ownerAbort(grant.attempt, now)
                if try await intents.resolve(grant.attempt, receipt: receipt, now: now) { resolved += 1 }
            } catch {
                try await intents.deferClaim(grant, now: now)
                if error is CancellationError { throw error }
                deferred += 1
            }
        }
        return .init(claimed: claimed.count, resolved: resolved, deferred: deferred)
    }
}

/// 即使组合层遗漏协调器，策略写入方也必须以安全方式失败。
/// 调用方持有对应的账号、关系或偏好独占锁。
func v2DrainDirectAuthorizations(_ scope: V2DirectAuthorizationRevocationScope,
    coordinator: V2DirectAuthorizationCoordinator?, transaction: any Database, now: Date) async throws {
    if let coordinator {
        try await coordinator.drain(scope, transaction: transaction, now: now)
    } else {
        let pending = try await PostgresV2DirectAuthorizationIntentStore(database: transaction)
            .held(in: scope, limit: 1, transaction: transaction)
        guard pending.isEmpty else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
    }
}
