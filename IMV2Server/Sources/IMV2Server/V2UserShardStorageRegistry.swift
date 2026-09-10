import Fluent
import Foundation
import IMV2Core

/// 将用户逻辑分片映射到部署配置的数据库与 schema 的运行时位置。
///
/// Fluent 的 `Database` 能力本身已是 `Sendable`；
/// 该不可变值刻意不携带任何自己的可变路由或连接池状态。
/// 只保存存储访问能力，不计算归属、不建立新连接，也不检查数据库或 schema 是否实际可用。
/// 逻辑标识仅验证去除首尾空白后非空，保存时保留原值，注册表查询按原字符串精确匹配。
public struct V2UserShardStorageLocation: Sendable {
    /// 用户逻辑分片标识，保留初始化输入的原始字符串。
    public let bucket: String
    /// 部署配置提供的 Fluent 数据库访问能力。
    public let database: any Database
    /// 通过标识符格式校验的 schema 名称；未验证其存在性或访问权限。
    public let schema: String

    /// 校验逻辑标识与 schema 的格式后保存位置。
    ///
    /// - Parameters:
    ///   - bucket: 非纯空白逻辑标识，不自动去除保存值的空白。
    ///   - database: 供后续存储操作使用的数据库。
    ///   - schema: 以 ASCII 字母或下划线开头，后续仅含 ASCII 字母、数字、下划线的名称。
    /// - Throws: 标识为空白或 schema 不满足正则格式时抛出 `invalidLocation`。
    public init(bucket: String, database: any Database, schema: String) throws {
        guard !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2UserShardStorageRegistryError.invalidLocation }
        self.bucket = bucket
        self.database = database
        self.schema = schema
    }
}

/// 用户分片存储配置与查找错误。
public enum V2UserShardStorageRegistryError: Error, Equatable, Sendable {
    /// 逻辑标识或 schema 格式无效。
    case invalidLocation
    /// 初始化注册表时遇到完全相同的逻辑标识。
    case duplicateBucket
    /// 当前注册表中未配置请求的逻辑标识。
    case unknownBucket
}

/// 根据已选定的用户逻辑分片解析部署位置，不接受客户端提供的连接地址。
public protocol V2UserShardStorageResolving: Sendable {
    /// 查询已配置的存储位置。
    ///
    /// - Parameter bucket: 归属路由选定的逻辑标识。
    /// - Returns: 对应数据库与 schema。
    /// - Throws: 配置缺失或实现特有的解析错误。
    func location(for bucket: String) throws -> V2UserShardStorageLocation
}

/// 持久化迁移的复制校验与转发阶段复核入口。
public protocol V2UserShardMigrationExecuting: Sendable {
    /// 执行投影复制与校验。
    ///
    /// - Parameter migrationID: 持久化迁移标识。
    /// - Returns: 执行后的迁移记录。
    /// - Throws: 记录缺失、位置解析、传输或协调器执行错误。
    func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord
    /// 执行转发阶段的一致性复核。
    ///
    /// - Parameter migrationID: 持久化迁移标识。
    /// - Returns: 执行后的迁移记录。
    /// - Throws: 记录缺失、位置解析、传输或协调器执行错误。
    func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord
}

/// 在路由控制层持有独占代次保护时完成最终物理同步。
///
/// 源到目标的最终复制与指纹相等检查成功后，调用方才可发布新归属；回滚按反方向同步。
/// 此接口不自行取得路由保护，也不自行更新路由。
public protocol V2UserShardCutoverFinalizing: Sendable {
    /// 从源向目标最终复制并验证指纹，成功后才允许外层发布路由变更。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - userID: 迁移所属用户。
    ///   - sourceBucket: 原始源桶，回滚时作为重建目的端。
    ///   - targetBucket: 原始目标桶，回滚时作为权威读取端。
    ///   - sourceRouterEpoch: 原始路由代次。
    ///   - controlTransaction: 持有路由保护的控制事务，同库桶可以复用该连接。
    /// - Throws: 存储解析、传输或数据库错误，以及最终指纹不一致错误。
    ///
    /// 调用方负责先持有独占路由保护；本方法不自行获取保护或变更归属。
    func finalizeForCutover(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws
    /// 从目标重建保留的源端并验证指纹，成功后才允许外层发布路由变更。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - userID: 迁移所属用户。
    ///   - sourceBucket: 原始源桶，回滚时作为重建目的端。
    ///   - targetBucket: 原始目标桶，回滚时作为权威读取端。
    ///   - sourceRouterEpoch: 原始路由代次。
    ///   - controlTransaction: 持有路由保护的控制事务，同库桶可以复用该连接。
    /// - Throws: 存储解析、传输或数据库错误，以及最终指纹不一致错误。
    ///
    /// 调用方负责先持有独占路由保护；本方法不自行获取保护或变更归属。
    func finalizeForRollback(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws
}

/// 初始化后不可变的用户分片位置注册表，允许空配置但不提供默认位置。
public struct V2StaticUserShardStorageRegistry: V2UserShardStorageResolving, Sendable {
    private let locations: [String: V2UserShardStorageLocation]

    /// 建立按原始逻辑标识索引的位置映射。
    ///
    /// - Parameter locations: 部署提供的位置列表，允许为空。
    /// - Throws: 逻辑标识重复时抛出 `duplicateBucket`，不会让后面的配置覆盖前面的配置。
    public init(locations: [V2UserShardStorageLocation]) throws {
        var result: [String: V2UserShardStorageLocation] = [:]
        for location in locations {
            guard result[location.bucket] == nil else { throw V2UserShardStorageRegistryError.duplicateBucket }
            result[location.bucket] = location
        }
        self.locations = result
    }

    /// 按原字符串精确查找，不修剪空白、不重新计算分片，也不回退到其他位置。
    ///
    /// - Parameter bucket: 需要解析的逻辑标识。
    /// - Returns: 初始化时保存的位置。
    /// - Throws: 未配置时抛出 `unknownBucket`。
    public func location(for bucket: String) throws -> V2UserShardStorageLocation {
        guard let location = locations[bucket] else { throw V2UserShardStorageRegistryError.unknownBucket }
        return location
    }
}

/// 将持久化迁移的逻辑桶解析为物理端点，并组装复制与校验协调器。
///
/// 任一桶未配置时在开始传输前失败。常规复制与复核委托协调器，最终切换与回滚
/// 由外层受保护的路由流程调用；本适配器不自行发布新归属。
public struct V2UserShardProjectionMigrationExecutor: V2UserShardMigrationExecuting, Sendable {
    private let store: any V2UserShardMigrationStoring
    private let registry: any V2UserShardStorageResolving
    private let pageSize: Int
    private let coLocatedControlBuckets: Set<String>
    private let now: @Sendable () -> Date

    /// 保存迁移依赖，不立即读库。
    ///
    /// - Parameters:
    ///   - store: 迁移记录存储。
    ///   - registry: 桶到物理位置的配置映射。
    ///   - pageSize: 传输分页大小，默认 1,000，须大于零。
    ///   - coLocatedControlBuckets: 与控制面同库的桶，最终切换时复用控制事务。
    ///   - now: 协调器使用的绝对时钟。
    /// - Precondition: 分页大小必须大于零。
    public init(
        store: any V2UserShardMigrationStoring,
        registry: any V2UserShardStorageResolving,
        pageSize: Int = 1_000,
        coLocatedControlBuckets: Set<String> = [],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(pageSize > 0)
        self.store = store
        self.registry = registry
        self.pageSize = pageSize
        self.coLocatedControlBuckets = coLocatedControlBuckets
        self.now = now
    }

    /// 执行投影复制与校验。
    ///
    /// - Parameter migrationID: 持久化迁移标识。
    /// - Returns: 执行后的迁移记录。
    /// - Throws: 记录缺失、位置解析、传输或协调器执行错误。
    public func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let record = try await store.load(migrationID: migrationID) else {
            throw V2UserShardMigrationStoreError.recordNotFound
        }
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        return try await V2DurableUserShardMigrationCoordinator(
            store: store, copier: transfer, verifier: transfer, now: now
        ).copyThenVerify(migrationID: migrationID)
    }

    /// 执行转发阶段的一致性复核。
    ///
    /// - Parameter migrationID: 持久化迁移标识。
    /// - Returns: 执行后的迁移记录。
    /// - Throws: 记录缺失、位置解析、传输或协调器执行错误。
    public func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let record = try await store.load(migrationID: migrationID) else {
            throw V2UserShardMigrationStoreError.recordNotFound
        }
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        return try await V2DurableUserShardMigrationCoordinator(
            store: store, copier: transfer, verifier: transfer, now: now
        ).verifyForwarding(migrationID: migrationID)
    }
}

extension V2UserShardProjectionMigrationExecutor: V2UserShardCutoverFinalizing {
    /// 从源向目标最终复制并验证指纹，成功后才允许外层发布路由变更。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - userID: 迁移所属用户。
    ///   - sourceBucket: 原始源桶，回滚时作为重建目的端。
    ///   - targetBucket: 原始目标桶，回滚时作为权威读取端。
    ///   - sourceRouterEpoch: 原始路由代次。
    ///   - controlTransaction: 持有路由保护的控制事务，同库桶可以复用该连接。
    /// - Throws: 存储解析、传输或数据库错误，以及最终指纹不一致错误。
    ///
    /// 调用方负责先持有独占路由保护；本方法不自行获取保护或变更归属。
    public func finalizeForCutover(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws {
        let context = try transferContext(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch,
            controlTransaction: controlTransaction
        )
        try await context.transfer.copy(context.record)
        let fingerprints = try await context.transfer.fingerprints(for: context.record)
        guard fingerprints.source == fingerprints.target else {
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
    }

    /// 从目标重建保留的源端并验证指纹，成功后才允许外层发布路由变更。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - userID: 迁移所属用户。
    ///   - sourceBucket: 原始源桶，回滚时作为重建目的端。
    ///   - targetBucket: 原始目标桶，回滚时作为权威读取端。
    ///   - sourceRouterEpoch: 原始路由代次。
    ///   - controlTransaction: 持有路由保护的控制事务，同库桶可以复用该连接。
    /// - Throws: 存储解析、传输或数据库错误，以及最终指纹不一致错误。
    ///
    /// 调用方负责先持有独占路由保护；本方法不自行获取保护或变更归属。
    public func finalizeForRollback(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws {
        let context = try transferContext(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch,
            controlTransaction: controlTransaction
        )
        let reverse = try PostgresV2UserShardProjectionTransfer(
            source: context.target.database, target: context.source.database,
            sourceBucket: context.record.targetBucket,
            targetBucket: context.record.sourceBucket,
            sourceSchema: context.target.schema, targetSchema: context.source.schema,
            pageSize: pageSize
        )
        let reverseRecord = V2UserShardMigrationRecord(
            migrationID: context.record.migrationID, userID: context.record.userID,
            sourceBucket: context.record.targetBucket,
            targetBucket: context.record.sourceBucket,
            sourceRouterEpoch: context.record.sourceRouterEpoch,
            phase: context.record.phase,
            sourceFingerprint: context.record.targetFingerprint,
            targetFingerprint: context.record.sourceFingerprint,
            verifiedAt: context.record.verifiedAt,
            lastErrorCode: context.record.lastErrorCode,
            cutoverOperationID: context.record.cutoverOperationID,
            retentionUntil: context.record.retentionUntil
        )
        // Sequence numbers are part of the sync contract and cannot be
        // reconciled row-by-row after the target has accepted post-cutover
        // writes. Rebuild the retained source from the authoritative target
        // while the route fence excludes all routed writes. A failure leaves
        // the route on the target; the operator can safely retry the rebuild.
        try await context.transfer.cleanSource(for: context.record)
        try await reverse.copy(reverseRecord)
        let fingerprints = try await reverse.fingerprints(for: reverseRecord)
        guard fingerprints.source == fingerprints.target else {
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
    }

    /// 从调用方已保护的参数构造临时迁移上下文，不重新加载记录。
    ///
    /// 同库桶复用控制事务连接；参数校验及路由保护由外层流程负责。
    private func transferContext(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) throws -> (
        record: V2UserShardMigrationRecord,
        source: V2UserShardStorageLocation,
        target: V2UserShardStorageLocation,
        transfer: PostgresV2UserShardProjectionTransfer
    ) {
        let record = V2UserShardMigrationRecord(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch, phase: .verified,
            sourceFingerprint: nil, targetFingerprint: nil
        )
        let configuredSource = try registry.location(for: sourceBucket)
        let configuredTarget = try registry.location(for: targetBucket)
        let source = try coLocatedControlBuckets.contains(sourceBucket)
            ? V2UserShardStorageLocation(
                bucket: configuredSource.bucket, database: controlTransaction,
                schema: configuredSource.schema
            ) : configuredSource
        let target = try coLocatedControlBuckets.contains(targetBucket)
            ? V2UserShardStorageLocation(
                bucket: configuredTarget.bucket, database: controlTransaction,
                schema: configuredTarget.schema
            ) : configuredTarget
        return (
            record, source, target,
            try PostgresV2UserShardProjectionTransfer(
                source: source.database, target: target.database,
                sourceBucket: source.bucket, targetBucket: target.bucket,
                sourceSchema: source.schema, targetSchema: target.schema,
                pageSize: pageSize
            )
        )
    }
}

/// 使用复制校验所用注册表解析存储位置的迁移源端清理适配器。
///
/// 仅能访问显式配置的桶，清理前的保留期限与路由状态检查由调用方负责。
public struct V2UserShardProjectionSourceCleaner: V2UserShardMigrationRetentionCleaning {
    private let registry: any V2UserShardStorageResolving
    private let pageSize: Int

    /// 创建清理适配器，不立即执行清理。
    ///
    /// - Parameters:
    ///   - registry: 迁移两端存储的配置映射。
    ///   - pageSize: 传输分页大小，默认 1,000，须为正数。
    /// - Precondition: 分页大小大于零。
    public init(registry: any V2UserShardStorageResolving, pageSize: Int = 1_000) {
        precondition(pageSize > 0)
        self.registry = registry
        self.pageSize = pageSize
    }

    /// 解析两端位置并委托投影传输器清理源端。
    ///
    /// - Parameter record: 调用方已确认满足清理条件的迁移记录。
    /// - Throws: 桶缺失、传输构造或底层清理错误。
    ///
    /// 本入口不自行检查保留期限、操作授权或路由归属，也不发布路由变化。
    public func cleanSource(for record: V2UserShardMigrationRecord) async throws {
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        try await transfer.cleanSource(for: record)
    }
}
