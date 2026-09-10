import Foundation

/// 运维迁移服务拒绝当前阶段执行请求时的错误。
public enum V2UserShardMigrationOperatorError: Error, Equatable, Sendable {
    /// 当前阶段不能按本入口启动所请求的工作。
    ///
    /// 初次复制入口用于表示 copying、copied 或 verifying；转发复核入口则对除 forwarding、
    /// verified 以外的所有阶段使用此错误，因此不能仅凭错误名判断是否确有后台任务在运行。
    case inProgress
}

/// 单用户迁移的运维编排入口，在物理执行器外处理准备请求与阶段相关的幂等返回。
///
/// 初次复制校验与转发复核分为两个入口，不自动执行路由切换。
/// 切换仍由单独授权且检查路由代次的控制流程完成。本服务不启动后台任务，调用会等待执行器返回；
/// 并发请求的最终阶段保护由存储及执行器负责，不以一次读取代替持久化并发检查。
public struct V2UserShardMigrationOperatorService: Sendable {
    private let store: any V2UserShardMigrationStoring
    private let executor: any V2UserShardMigrationExecuting
    private let now: @Sendable () -> Date

    /// 保存控制记录存储与物理迁移执行器，不立即执行迁移。
    ///
    /// - Parameters:
    ///   - store: 负责准备请求一致性和阶段持久化的存储。
    ///   - executor: 执行复制校验及转发复核的适配器。
    ///   - now: 准备记录时使用的绝对时钟；执行器内部计时由其自身依赖负责。
    public init(
        store: any V2UserShardMigrationStoring,
        executor: any V2UserShardMigrationExecuting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.executor = executor
        self.now = now
    }

    /// 准备迁移记录，并在允许的阶段同步等待初次复制与校验。
    ///
    /// 存储确认请求一致后，已处于 forwarding 时直接幂等返回；prepared 或 failed 调用执行器。
    /// copying、copied、verifying 拒绝为 inProgress；verified 及之后阶段拒绝为非法转换。
    ///
    /// - Parameter request: 已规范化的迁移准备请求，重复请求须满足存储的一致性约束。
    /// - Returns: 迁移记录及幂等标记；只有复用 forwarding 记录时标记为 `true`。
    ///   调用执行器成功时标记为 `false`，本服务不再次验证其返回阶段。
    /// - Throws: 准备请求冲突、阶段拒绝、持久化或执行器错误，均向调用方传播。
    public func prepareCopyAndVerify(
        _ request: V2UserShardMigrationPreparation
    ) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        let prepared = try await store.prepare(request, now: now())
        switch prepared.phase {
        case .forwarding:
            return (prepared, true)
        case .prepared, .failed:
            return (try await executor.copyThenVerify(migrationID: prepared.migrationID), false)
        case .copying, .copied, .verifying:
            throw V2UserShardMigrationOperatorError.inProgress
        case .verified, .cutover, .retention, .completed, .rolledBack:
            throw V2UserShardMigrationError.invalidTransition
        }
    }

    /// 根据当前阶段复核转发结果，已验证记录直接幂等返回。
    ///
    /// - Parameter migrationID: 要复核的迁移标识。
    /// - Returns: verified 记录直接返回且幂等标记为 `true`；forwarding 时返回执行器结果并标记 `false`。
    /// - Throws: 记录不存在抛出 `recordNotFound`；除 forwarding、verified 外的任何阶段均抛出
    ///   `inProgress`，包括终态；查询和执行器错误原样传播。
    public func verifyForwarding(migrationID: UUID) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        guard let current = try await store.load(migrationID: migrationID) else { throw V2UserShardMigrationStoreError.recordNotFound }
        switch current.phase {
        case .verified: return (current, true)
        case .forwarding: return (try await executor.verifyForwarding(migrationID: migrationID), false)
        default: throw V2UserShardMigrationOperatorError.inProgress
        }
    }
}

/// 为运维传输层暴露初次复制校验能力，不包含路由切换。
public protocol V2UserShardMigrationCopyVerifyHandling: Sendable {
    /// 准备请求并执行或复用初次复制校验结果。
    ///
    /// - Parameter request: 迁移准备参数。
    /// - Returns: 控制记录和是否幂等复用的标记。
    /// - Throws: 请求、阶段、存储或执行错误。
    func prepareCopyAndVerify(
        _ request: V2UserShardMigrationPreparation
    ) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
}

/// 为运维传输层暴露转发复核能力，与初次复制请求分离。
public protocol V2UserShardMigrationForwardingVerifyHandling: Sendable {
    /// 执行或复用转发阶段复核结果。
    ///
    /// - Parameter migrationID: 迁移标识。
    /// - Returns: 控制记录和是否幂等复用的标记。
    /// - Throws: 记录缺失、阶段拒绝、存储或执行错误。
    func verifyForwarding(migrationID: UUID) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
}

extension V2UserShardMigrationOperatorService: V2UserShardMigrationCopyVerifyHandling {}
extension V2UserShardMigrationOperatorService: V2UserShardMigrationForwardingVerifyHandling {}
