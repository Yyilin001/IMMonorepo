import Foundation

/// 一次邀请创建恢复的认领结果。
public struct V2GroupInviteCreationRecoveryClaim: Sendable {
    /// 待恢复的创建意图。
    public let intent: V2GroupInviteCreationIntent
    /// 本次认领令牌。
    public let claimToken: UUID
    /// 已尝试次数，从 1 开始。
    public let attemptCount: Int
}

/// 邀请创建恢复的失败分类。
public enum V2GroupInviteCreationRecoveryFailure: String, Sendable {
    /// 依赖当前不可用，可自动重试。
    case dependencyUnavailable = "dependency_unavailable"
    /// 房间归属已变更。
    case ownerChanged = "owner_changed"
    /// 被限流。
    case rateLimited = "rate_limited"
    /// 权限被拒绝，需暂停并等待人工处理。
    case permissionDenied = "permission_denied"
    /// 邀请创建已过期，需暂停。
    case creationExpired = "creation_expired"
    /// 证据互相冲突，需暂停。
    case conflictingEvidence = "conflicting_evidence"
}

/// 邀请创建恢复任务的持久化能力。
public protocol V2GroupInviteCreationRecoveryStoring: Sendable {
    /// 认领一批待恢复的创建任务。
    ///
    /// - Parameters:
    ///   - limit: 本次最多认领的任务数。
    ///   - now: 本次认领时刻。
    ///   - lease: 认领租约时长秒数。
    ///   - maximumActiveInvitesPerRoom: 房间允许的活跃邀请上限。
    /// - Returns: 认领到的任务列表。
    /// - Throws: 持久化失败时抛出。
    func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim]

    /// 记录一次恢复失败并决定延期或暂停。
    ///
    /// 只有仍然持有有效认领的任务才会被延期或暂停：前台完成路径可能已把该任务
    /// 与目录发布一起原子提交，此时本调用不应覆盖结果。
    ///
    /// - Parameters:
    ///   - claim: 本次认领结果。
    ///   - reason: 失败分类。
    ///   - retryAt: 下次重试时刻；暂停时为空。
    ///   - now: 本次记录时刻。
    /// - Returns: 记录实际生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool
}

/// 可恢复未完成邀请创建的能力。
public protocol V2GroupInviteCreationResuming: Sendable {
    /// 以给定时刻重放一次创建意图。
    ///
    /// - Parameters:
    ///   - intent: 待恢复的创建意图。
    ///   - now: 本次恢复使用的服务端时刻。
    /// - Throws: 创建失败时抛出，调用方据错误分类决定延期或暂停。
    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws
}

/// 单轮邀请创建恢复的统计。
public struct V2GroupInviteCreationRecoveryReport: Equatable, Sendable {
    /// 本轮尝试恢复的数量。
    public var attempted = 0
    /// 成功完成的数量。
    public var completed = 0
    /// 延期重试的数量。
    public var deferred = 0
    /// 暂停等待人工处理的数量。
    public var paused = 0
    /// 因认领已失效而放弃记录的数量。
    public var lostClaim = 0
}

/// 邀请创建恢复工作器。
///
/// 每次只认领一个任务，避免某个缓慢归属耗尽本地批次中其他任务租约；多个账号进程
/// 可安全共享同一队列。恢复过程不需要邀请明文密钥。
public struct V2GroupInviteCreationRecoveryWorker: Sendable {
    private let jobs: any V2GroupInviteCreationRecoveryStoring
    private let invitations: any V2GroupInviteCreationResuming
    private let policy: V2GroupInvitationPolicy
    private let now: @Sendable () -> Date

    /// 组合恢复任务存储、创建恢复入口与邀请策略。
    ///
    /// - Parameters:
    ///   - jobs: 恢复任务的持久化存储。
    ///   - invitations: 执行创建恢复的入口。
    ///   - policy: 邀请策略，默认使用标准值。
    ///   - now: 可注入的当前时刻读取函数。
    public init(jobs: any V2GroupInviteCreationRecoveryStoring, invitations: any V2GroupInviteCreationResuming, policy: V2GroupInvitationPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.jobs = jobs; self.invitations = invitations; self.policy = policy; self.now = now
    }

    public init(jobs: any V2GroupInviteCreationRecoveryStoring,
                coordinator: V2ActorInvitationCoordinator,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant,
                policy: V2GroupInvitationPolicy = .standard,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.init(jobs: jobs,
                  invitations: V2ActorInvitationCreationResumer(coordinator: coordinator, deadline: deadline),
                  policy: policy, now: now)
    }

    /// 执行一轮有界恢复。
    ///
    /// 权限拒绝、创建过期与证据冲突会暂停任务；其余失败按有上限的指数退避延期，
    /// 使暂时不可用的依赖无论中断多久都能自动恢复。任务取消会向上传播，
    /// 让下一次进程重试同一持久化创建操作。
    ///
    /// - Parameter limit: 本轮最多处理的任务数，需落在 `1...100`。
    /// - Returns: 本轮恢复统计。
    /// - Throws: 条数越界或恢复时间无法编码时抛出
    ///   ``V2GroupInviteDirectoryError/invalidRequest``；任务取消时抛出 `CancellationError`。
    public func runOnce(limit: Int = 8) async throws -> V2GroupInviteCreationRecoveryReport {
        guard (1...100).contains(limit) else { throw V2GroupInviteDirectoryError.invalidRequest }
        var report = V2GroupInviteCreationRecoveryReport()
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard let claim = try await jobs.claim(limit: 1, now: now(), lease: 60, maximumActiveInvitesPerRoom: policy.maximumActiveInvitesPerRoom).first else { break }
            report.attempted += 1
            let resumedAt = now()
            // Validate the attempt clock before business-error classification.
            // Preparing the resumed intent needs a representable recovery date.
            guard v2PostgresFutureTimestamp(now: resumedAt, interval: 30) != nil else {
                throw V2GroupInviteDirectoryError.invalidRequest
            }
            do {
                try Task.checkCancellation()
                try await invitations.resumeCreation(claim.intent, now: resumedAt)
                report.completed += 1
            } catch is CancellationError {
                // An interrupted/uncertain owner call retains the lease; the
                // next process will retry the exact durable creation operation.
                throw CancellationError()
            } catch {
                let reason = classify(error)
                let current = now()
                guard v2PostgresTimestampCanEncode(current) else { throw V2GroupInviteDirectoryError.invalidRequest }
                let shouldPause = reason == .permissionDenied || reason == .creationExpired || reason == .conflictingEvidence
                // Transient dependencies recover automatically, however long
                // they were unavailable. Saturated attempts cannot overflow.
                let delay = min(900.0, 15.0 * pow(2.0, Double(min(max(1, claim.attemptCount), 7) - 1)))
                let retryAt: Date?
                if shouldPause { retryAt = nil }
                else {
                    guard let deadline = v2PostgresFutureTimestamp(now: current, interval: delay) else {
                        throw V2GroupInviteDirectoryError.invalidRequest
                    }
                    retryAt = deadline
                }
                let recorded = try await jobs.fail(claim, reason: reason, retryAt: retryAt, now: current)
                if !recorded { report.lostClaim += 1 }
                else if shouldPause { report.paused += 1 }
                else { report.deferred += 1 }
            }
        }
        return report
    }

    /// 把创建错误归类为恢复失败原因。
    ///
    /// 未知错误统一按依赖不可用处理，使其进入自动重试而不是被静默暂停。
    ///
    /// - Parameter error: 恢复过程中抛出的错误。
    /// - Returns: 对应的失败分类。
    private func classify(_ error: any Error) -> V2GroupInviteCreationRecoveryFailure {
        if let error = error as? V2GroupInvitationServiceError {
            switch error {
            case .permissionDenied: return .permissionDenied
            case .creationExpired: return .creationExpired
            case .ownerChanged: return .ownerChanged
            case .rateLimited: return .rateLimited
            case .invalidRequest, .conflict, .corruptPersistenceState: return .conflictingEvidence
            case .invalidConfiguration, .roomNotFound, .inviteNotFound, .requestNotFound: return .dependencyUnavailable
            }
        }
        if error is V2GroupInviteDirectoryError { return .conflictingEvidence }
        return .dependencyUnavailable
    }
}
