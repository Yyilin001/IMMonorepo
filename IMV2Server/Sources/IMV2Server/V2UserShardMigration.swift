import Foundation
import IMV2Core

/// 用户分片迁移的持久化阶段集合，原始值用于序列化。
///
/// 正常路径为 prepared → copying → copied → verifying → forwarding → verified → cutover
/// → retention → completed。回滚只允许从 cutover 或 retention 进入 rolledBack；
/// 切换前各阶段可标记 failed，再通过显式复制或验证动作重试。
/// 阶段本身不执行数据搬迁，也不是跨存储数据一致性的独立证明。
public enum V2UserShardMigrationPhase: String, Codable, Equatable, Sendable {
    case prepared, copying, copied, verifying, forwarding, verified, cutover, retention, completed, rolledBack = "rolled_back", failed
}

/// 迁移状态机接受的动作；动作只描述阶段推进意图，不执行外部副作用。
public enum V2UserShardMigrationAction: Equatable, Sendable {
    case beginCopy, copySucceeded, beginVerification, verificationSucceeded, forwardingVerificationSucceeded
    case cutOver, beginRetention, complete, rollback, fail
}

/// 当前阶段不接受指定动作时产生的状态转换错误。
public enum V2UserShardMigrationError: Error, Equatable, Sendable { case invalidTransition }

/// 无副作用的迁移阶段转换规则，不读取存储、不验证指纹，也不更新路由。
public struct V2UserShardMigrationStateMachine: Sendable {
    /// 根据当前阶段和动作计算下一阶段。
    ///
    /// - Parameters:
    ///   - phase: 调用方观察到的当前阶段。
    ///   - action: 请求执行的状态动作。
    /// - Returns: 合法组合对应的新阶段。
    /// - Throws: 非法组合抛出 `V2UserShardMigrationError.invalidTransition`。
    ///
    /// 不支持已完成后回滚，也不将重复动作默认为成功；并发阶段校验由存储层负责。
    public static func transition(from phase: V2UserShardMigrationPhase, by action: V2UserShardMigrationAction) throws -> V2UserShardMigrationPhase {
        switch (phase, action) {
        case (.prepared, .beginCopy), (.failed, .beginCopy): return .copying
        case (.copying, .copySucceeded): return .copied
        case (.copied, .beginVerification), (.failed, .beginVerification): return .verifying
        case (.verifying, .verificationSucceeded): return .forwarding
        case (.forwarding, .forwardingVerificationSucceeded): return .verified
        case (.verified, .cutOver): return .cutover
        case (.cutover, .beginRetention): return .retention
        case (.retention, .complete): return .completed
        // Rollback is deliberately unavailable after cleanup/complete.
        case (.cutover, .rollback), (.retention, .rollback): return .rolledBack
        case (.prepared, .fail), (.copying, .fail), (.copied, .fail), (.verifying, .fail), (.forwarding, .fail), (.verified, .fail): return .failed
        default: throw V2UserShardMigrationError.invalidTransition
        }
    }
}

/// 迁移控制记录的值快照，构造时仅保存字段，不校验阶段与可选元数据的一致性。
public struct V2UserShardMigrationRecord: Equatable, Sendable {
    /// 迁移任务标识。
    public let migrationID: UUID
    /// 迁移所属用户。
    public let userID: UserID
    /// 原始源逻辑桶。
    public let sourceBucket: String
    /// 目标逻辑桶。
    public let targetBucket: String
    /// 开始迁移时所依据的源路由代次。
    public let sourceRouterEpoch: Int64
    /// 当前持久化迁移阶段。
    public let phase: V2UserShardMigrationPhase
    /// 最近保存的源端指纹，尚无校验结果时可为空。
    public let sourceFingerprint: String?
    /// 最近保存的目标端指纹，尚无校验结果时可为空。
    public let targetFingerprint: String?
    /// 保存的校验时间，未提供时为空。
    public let verifiedAt: Date?
    /// 最近记录的固定失败类别，不包含底层原始错误文本。
    public let lastErrorCode: V2UserShardMigrationFailureCode?
    /// 关联的路由切换操作标识，尚未关联时可为空。
    public let cutoverOperationID: UUID?
    /// 保留源端以支持回滚的期限，未进入相应流程时可为空。
    public let retentionUntil: Date?

    /// 构造迁移记录快照，不执行持久化或阶段转换。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移任务标识。
    ///   - userID: 迁移所属用户。
    ///   - sourceBucket: 原始源逻辑桶。
    ///   - targetBucket: 目标逻辑桶。
    ///   - sourceRouterEpoch: 开始迁移时所依据的源路由代次。
    ///   - phase: 当前持久化迁移阶段。
    ///   - sourceFingerprint: 最近保存的源端指纹，尚无校验结果时可为空。
    ///   - targetFingerprint: 最近保存的目标端指纹，尚无校验结果时可为空。
    ///   - verifiedAt: 保存的校验时间，未提供时为空。
    ///   - lastErrorCode: 最近记录的固定失败类别，不包含底层原始错误文本。
    ///   - cutoverOperationID: 关联的路由切换操作标识，尚未关联时可为空。
    ///   - retentionUntil: 保留源端以支持回滚的期限，未进入相应流程时可为空。
    public init(
        migrationID: UUID,
        userID: UserID,
        sourceBucket: String,
        targetBucket: String,
        sourceRouterEpoch: Int64,
        phase: V2UserShardMigrationPhase,
        sourceFingerprint: String?,
        targetFingerprint: String?,
        verifiedAt: Date? = nil,
        lastErrorCode: V2UserShardMigrationFailureCode? = nil,
        cutoverOperationID: UUID? = nil,
        retentionUntil: Date? = nil
    ) {
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = sourceBucket
        self.targetBucket = targetBucket
        self.sourceRouterEpoch = sourceRouterEpoch
        self.phase = phase
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.verifiedAt = verifiedAt
        self.lastErrorCode = lastErrorCode
        self.cutoverOperationID = cutoverOperationID
        self.retentionUntil = retentionUntil
    }
}

/// 适合持久化的固定迁移失败类别。
///
/// 不保存适配器原始错误文本，避免将主机名、标识符等运行信息写入控制记录。
public enum V2UserShardMigrationFailureCode: String, Codable, Equatable, Sendable {
    /// 复制器执行失败。
    case copyFailed = "copy_failed"
    /// 指纹读取或计算失败。
    case verificationFailed = "verification_failed"
    /// 指纹计算成功但源端与目标端不相等。
    case fingerprintMismatch = "fingerprint_mismatch"
}

/// 创建迁移记录前的规范化请求，不读取路由或验证两端物理配置。
public struct V2UserShardMigrationPreparation: Sendable {
    /// 本次迁移任务标识。
    public let migrationID: UUID
    /// 需要迁移的用户。
    public let userID: UserID
    /// 去除首尾空白后的源桶。
    public let sourceBucket: String
    /// 经用户路由值验证的目标桶。
    public let targetBucket: String
    /// 请求所依据的源路由代次。
    public let sourceRouterEpoch: Int64

    /// 验证源桶非空、与目标不同，并复用用户路由值校验目标及代次。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - userID: 迁移用户。
    ///   - sourceBucket: 原始源桶，首尾空白会移除。
    ///   - targetBucket: 目标桶，交由 `V2UserShardRoute` 规范化及验证。
    ///   - sourceRouterEpoch: 交由路由值验证的源代次。
    /// - Throws: 源桶为空或与目标相同时抛出 `invalidPreparation`；目标路由校验错误原样传播。
    public init(migrationID: UUID, userID: UserID, sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64) throws {
        let route = try V2UserShardRoute(bucket: targetBucket, observedRouterEpoch: sourceRouterEpoch)
        let source = sourceBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source != route.bucket else { throw V2UserShardMigrationStoreError.invalidPreparation }
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = source
        self.targetBucket = route.bucket
        self.sourceRouterEpoch = sourceRouterEpoch
    }
}

/// 迁移控制记录的请求、阶段与指纹约束错误。
public enum V2UserShardMigrationStoreError: Error, Equatable, Sendable {
    /// 迁移准备参数不符合约束。
    case invalidPreparation
    /// 请求的迁移记录不存在。
    case recordNotFound
    /// 已有记录与本次准备请求不一致。
    case requestConflict
    /// 持久化当前阶段与调用方预期不一致。
    case phaseConflict
    /// 指纹缺失、格式无效、不相等，或在不接受指纹的动作中提供了指纹。
    case invalidFingerprint
}

/// 迁移控制记录的持久化边界，负责核对预期阶段后再推进状态。
///
/// 外部复制与校验应在存储事务之外执行，再以预期阶段提交结果，避免长时间持有控制事务。
/// 阶段推进不等同于物理路由切换；路由发布由相应控制流程负责。
public protocol V2UserShardMigrationStoring: Sendable {
    /// 准备迁移控制记录，已有兼容请求可由实现返回原记录。
    ///
    /// - Parameters:
    ///   - request: 已规范化的准备请求。
    ///   - now: 本次持久化使用的时间。
    /// - Returns: 新建或匹配的迁移记录。
    /// - Throws: 请求冲突或持久化错误。
    func prepare(_ request: V2UserShardMigrationPreparation, now: Date) async throws -> V2UserShardMigrationRecord
    /// 按迁移任务读取当前控制记录，不执行阶段变更。
    ///
    /// - Parameter migrationID: 查询标识。
    /// - Returns: 对应记录，不存在时为 `nil`。
    /// - Throws: 底层查询或数据解码错误。
    func load(migrationID: UUID) async throws -> V2UserShardMigrationRecord?
    /// 按用户读取当前控制记录，不执行阶段变更。
    ///
    /// - Parameter userID: 查询标识。
    /// - Returns: 对应记录，不存在时为 `nil`。
    /// - Throws: 底层查询或数据解码错误。
    func load(userID: UserID) async throws -> V2UserShardMigrationRecord?
    /// 核对预期阶段后按动作推进记录，必要时保存校验指纹。
    ///
    /// - Parameters:
    ///   - migrationID: 要更新的迁移标识。
    ///   - expectedPhase: 调用方据以执行动作的阶段，必须仍与持久化状态一致。
    ///   - action: 状态机允许的动作。
    ///   - fingerprints: 验证成功动作所需的两端指纹，其他动作不应提供。
    ///   - now: 状态更新与验证时间使用的绝对日期。
    /// - Returns: 成功更新后的记录。
    /// - Throws: 记录缺失、阶段冲突、非法转换、指纹无效或持久化错误。
    func advance(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        action: V2UserShardMigrationAction,
        fingerprints: (source: String, target: String)?,
        now: Date
    ) async throws -> V2UserShardMigrationRecord
    /// 在预期阶段仍匹配时记录失败，不保存原始适配器错误文本。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移标识。
    ///   - expectedPhase: 失败所对应的预期阶段。
    ///   - code: 固定失败类别。
    ///   - now: 状态更新时刻。
    /// - Returns: 失败阶段的记录。
    /// - Throws: 记录缺失、阶段冲突、当前阶段不允许失败动作或持久化错误。
    func fail(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        code: V2UserShardMigrationFailureCode,
        now: Date
    ) async throws -> V2UserShardMigrationRecord
}

/// 源端保留期清理的领取凭据，携带领取时的记录与完成令牌。
public struct V2UserShardMigrationRetentionLease: Equatable, Sendable {
    /// 领取时处于保留阶段的控制记录快照。
    public let record: V2UserShardMigrationRecord
    /// 本次领取令牌，用于完成时排除已经被其他领取取代的工作。
    public let claimToken: UUID

    /// 保存领取记录与令牌，不验证租约到期时间。
    ///
    /// - Parameters:
    ///   - record: 保留阶段的迁移记录。
    ///   - claimToken: 持久化领取令牌。
    /// - Precondition: 记录阶段必须为 `retention`。
    public init(record: V2UserShardMigrationRecord, claimToken: UUID) {
        precondition(record.phase == .retention)
        self.record = record
        self.claimToken = claimToken
    }
}

/// 为保留期结束后的源端清理提供有界领取与令牌保护的完成接口。
///
/// 外部删除在领取事务结束后执行；租约到期可被重新领取，因此清理器必须允许重复执行。
public protocol V2UserShardMigrationRetentionStoring: Sendable {
    /// 领取保留期已到且当前可领取的清理任务。
    ///
    /// - Parameters:
    ///   - now: 判断保留期和旧租约到期的基准日期。
    ///   - leaseDuration: 新租约时长，单位秒。
    ///   - limit: 本轮领取数量上限。
    /// - Returns: 领取的记录与令牌，可为空。
    /// - Throws: 时间不可持久化或底层领取错误。
    func claimExpiredRetention(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserShardMigrationRetentionLease]
    /// 在记录阶段和领取令牌仍匹配时登记清理完成。
    ///
    /// - Parameters:
    ///   - lease: 清理所依据的领取凭据。
    ///   - now: 完成记录更新时间。
    /// - Returns: 成功标记完成为 `true`；阶段或令牌不再匹配时为 `false`。
    /// - Throws: 底层更新错误。
    ///
    /// 当前 PostgreSQL 实现匹配阶段与令牌，不额外检查租约时间是否已经到期。
    func completeRetention(_ lease: V2UserShardMigrationRetentionLease, now: Date) async throws -> Bool
}

/// 实际删除已过保留期源端投影的外部副作用边界。
public protocol V2UserShardMigrationRetentionCleaning: Sendable {
    /// 幂等清理已完成复制、验证且超过回滚保留窗口的源端数据。
    ///
    /// - Parameter record: 由保留期领取流程提供的迁移记录。
    /// - Throws: 清理失败的存储或传输错误，调用方可在租约到期后重试。
    ///
    /// 同一迁移可能被重复清理，不能依赖只有一次调用。
    func cleanSource(for record: V2UserShardMigrationRecord) async throws
}

/// 单轮保留期清理的结果；完成登记返回 `false` 的任务不计为完成或失败。
public struct V2UserShardMigrationRetentionReport: Equatable, Sendable {
    /// 本轮实际取得的租约数。
    public let claimedCount: Int
    /// 清理返回且完成登记返回 `true` 的数量。
    public let completedCount: Int
    /// 清理或完成登记抛错的数量，不包含返回 `false` 的情况。
    public let failedCount: Int
}

/// 顺序处理一批源端保留期清理任务，不持有跨外部删除调用的控制事务。
///
/// 单项失败保留租约至到期，由后续领取重试；不在本轮热循环重试，也不自动续租。
public struct V2UserShardMigrationRetentionWorker: Sendable {
    private let store: any V2UserShardMigrationRetentionStoring
    private let cleaner: any V2UserShardMigrationRetentionCleaning
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    /// 配置清理依赖，不启动周期任务。
    ///
    /// - Parameters:
    ///   - store: 租约领取与完成存储。
    ///   - cleaner: 幂等源端清理器。
    ///   - leaseDuration: 租约秒数，默认 60，须大于零；实际可编码性由存储验证。
    ///   - now: 领取和逐项完成时读取的绝对时钟。
    /// - Precondition: 租约时长大于零。
    public init(
        store: any V2UserShardMigrationRetentionStoring,
        cleaner: any V2UserShardMigrationRetentionCleaning,
        leaseDuration: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.store = store
        self.cleaner = cleaner
        self.leaseDuration = leaseDuration
        self.now = now
    }

    /// 领取并顺序清理一轮任务，逐项尝试登记完成。
    ///
    /// - Parameter limit: 领取数量上限，须为正数。
    /// - Returns: 领取、完成和抛错数量；三者不保证满足领取数等于另两者之和。
    /// - Throws: 领取阶段错误直接传播；逐项清理和完成登记错误被计入失败数。
    /// - Precondition: `limit` 大于零。
    ///
    /// 逐项捕获也包含取消错误，本循环不自行检查取消信号；不会自动续租。
    public func runOnce(limit: Int) async throws -> V2UserShardMigrationRetentionReport {
        precondition(limit > 0)
        let leases = try await store.claimExpiredRetention(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        var failed = 0
        for lease in leases {
            do {
                try await cleaner.cleanSource(for: lease.record)
                if try await store.completeRetention(lease, now: now()) { completed += 1 }
            } catch {
                // Retain the claim through expiry to avoid a hot destructive
                // retry loop. A later worker can reclaim it with a new token.
                failed += 1
            }
        }
        return .init(claimedCount: leases.count, completedCount: completed, failedCount: failed)
    }
}

/// 用户投影物理复制边界，与指纹计算解耦，便于独立注入存储实现和测试替身。
///
/// 实现可采用流式或检查点复制；恢复流程需要能够安全重试的复制策略。
public protocol V2UserShardMigrationCopying: Sendable {
    /// 按迁移记录复制源端数据；具体分页、检查点及幂等规则由适配器负责。
    ///
    /// - Parameter record: 当前迁移上下文。
    /// - Throws: 复制过程中发生的存储或传输错误。
    func copy(_ record: V2UserShardMigrationRecord) async throws
}

/// 为迁移两端计算可比较指纹的验证边界，不自行推进阶段。
public protocol V2UserShardMigrationVerifying: Sendable {
    /// 读取并计算两端指纹，是否相等由调用方判断。
    ///
    /// - Parameter record: 需要校验的迁移上下文。
    /// - Returns: 源端与目标端的指纹字符串。
    /// - Throws: 读取或指纹计算错误。
    func fingerprints(for record: V2UserShardMigrationRecord) async throws -> (source: String, target: String)
}

/// 两端指纹不相等，不能认定迁移数据一致。
public enum V2UserShardMigrationVerificationError: Error, Equatable, Sendable { case fingerprintMismatch }

/// 编排单次用户分片复制和指纹校验，以持久化阶段检查保护每次状态推进。
///
/// 外部复制和校验在独立存储调用之间执行，本协调器不持有跨这些调用的数据库事务。
/// 初次复制校验进入转发阶段，再次验证转发结果才进入已验证阶段；两者都不发布新路由。
/// 外部操作失败时尽力登记固定失败码，登记本身失败不会覆盖原始错误。
/// 进程中断可能留下中间阶段，重试与恢复由上层流程处理，本类型不自动从任意阶段续跑。
public struct V2DurableUserShardMigrationCoordinator: Sendable {
    private let store: any V2UserShardMigrationStoring
    private let copier: any V2UserShardMigrationCopying
    private let verifier: any V2UserShardMigrationVerifying
    private let now: @Sendable () -> Date

    /// 保存单次迁移编排所需依赖，不立即执行迁移。
    ///
    /// - Parameters:
    ///   - store: 带预期阶段检查的持久化迁移存储。
    ///   - copier: 外部投影复制器。
    ///   - verifier: 两端指纹计算器。
    ///   - now: 阶段持久化使用的绝对时钟。
    public init(
        store: any V2UserShardMigrationStoring,
        copier: any V2UserShardMigrationCopying,
        verifier: any V2UserShardMigrationVerifying,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.copier = copier
        self.verifier = verifier
        self.now = now
    }

    /// 从准备或失败阶段开始复制，完成初次指纹校验后进入转发阶段。
    ///
    /// 状态依次推进为 `copying`、`copied`、`verifying` 和 `forwarding`。
    /// 复制器或校验器抛错时尽力登记失败码并重抛原错；指纹不一致则登记对应失败码并抛错。
    /// 阶段存储调用失败直接传播，不保证额外写入失败状态。
    ///
    /// - Parameter migrationID: 当前处于 `prepared` 或 `failed` 的持久化迁移标识。
    /// - Returns: 初次校验成功后的 `forwarding` 记录，尚不能据此直接切换路由。
    /// - Throws: 记录缺失或阶段不允许时抛出 `invalidTransition`；复制、存储或校验错误
    ///   原样传播；两端指纹不等时抛出 `fingerprintMismatch`。
    public func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let current = try await store.load(migrationID: migrationID),
              current.phase == .prepared || current.phase == .failed
        else { throw V2UserShardMigrationError.invalidTransition }

        let copying = try await store.advance(
            migrationID: migrationID, expectedPhase: current.phase,
            action: .beginCopy, fingerprints: nil, now: now()
        )
        do {
            try await copier.copy(copying)
        } catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .copying, code: .copyFailed, now: now())
            throw error
        }

        let copied = try await store.advance(
            migrationID: migrationID, expectedPhase: .copying,
            action: .copySucceeded, fingerprints: nil, now: now()
        )
        let verifying = try await store.advance(
            migrationID: migrationID, expectedPhase: copied.phase,
            action: .beginVerification, fingerprints: nil, now: now()
        )
        let fingerprints: (source: String, target: String)
        do {
            fingerprints = try await verifier.fingerprints(for: verifying)
        } catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .verifying, code: .verificationFailed, now: now())
            throw error
        }
        guard fingerprints.source == fingerprints.target else {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .verifying, code: .fingerprintMismatch, now: now())
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
        return try await store.advance(
            migrationID: migrationID, expectedPhase: .verifying,
            action: .verificationSucceeded, fingerprints: fingerprints, now: now()
        )
    }

    /// 复核转发阶段的两端指纹，相等后推进到已验证阶段。
    ///
    /// 本方法不执行复制，也不等待转发器追平；调用方应在适当时机请求复核。
    /// 校验失败或指纹不等时尽力登记失败码，不会自动切换路由。
    ///
    /// - Parameter migrationID: 当前处于 `forwarding` 的迁移标识。
    /// - Returns: 指纹相等且阶段推进成功后的 `verified` 记录。
    /// - Throws: 记录缺失或阶段错误时抛出 `invalidTransition`；指纹不等抛出
    ///   `fingerprintMismatch`；校验器和存储错误原样传播。
    public func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let current = try await store.load(migrationID: migrationID), current.phase == .forwarding else {
            throw V2UserShardMigrationError.invalidTransition
        }
        let fingerprints: (source: String, target: String)
        do { fingerprints = try await verifier.fingerprints(for: current) }
        catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .forwarding, code: .verificationFailed, now: now())
            throw error
        }
        guard fingerprints.source == fingerprints.target else {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .forwarding, code: .fingerprintMismatch, now: now())
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
        return try await store.advance(
            migrationID: migrationID, expectedPhase: .forwarding,
            action: .forwardingVerificationSucceeded, fingerprints: fingerprints, now: now()
        )
    }
}
