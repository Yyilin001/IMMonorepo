import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 内容审核边界接收做出判定所需的最小消息表示。
///
/// 它刻意不含设备、接收者、对象存储位置、文件名或传输凭据。
public struct V2ContentReviewInput: Sendable {
    /// 目标消息。
    public let messageID: MessageID
    /// 目标房间。
    public let roomID: RoomID
    /// 消息内容修订。
    public let contentRevision: UInt64
    /// 消息正文。
    public let text: String
    /// 附件数量。
    public let mediaCount: Int

    /// 保存审核输入。
    ///
    /// - Parameters:
    ///   - messageID: 目标消息。
    ///   - roomID: 目标房间。
    ///   - contentRevision: 内容修订。
    ///   - text: 消息正文。
    ///   - mediaCount: 附件数量。
    public init(messageID: MessageID, roomID: RoomID, contentRevision: UInt64, text: String, mediaCount: Int) {
        self.messageID = messageID
        self.roomID = roomID
        self.contentRevision = contentRevision
        self.text = text
        self.mediaCount = mediaCount
    }
}

/// 违规发现。
///
/// 策略数据刻意只存在于代码中；提供方的详细输出应保存在独立的证据系统，
/// 绝不能进入同步事件或通用日志。
public struct V2ContentReviewFinding: Equatable, Sendable {
    /// 违规类别。
    public let category: String
    /// 严重程度。
    public let severity: Int
    /// 置信度。
    public let confidence: Double

    public init(category: String, severity: Int, confidence: Double) throws {
        guard !category.isEmpty,
              category.utf8.count <= 64,
              category.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw V2ContentReviewWorkerError.invalidFindingCategory }
        guard (0...4).contains(severity) else { throw V2ContentReviewWorkerError.invalidFindingSeverity }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw V2ContentReviewWorkerError.invalidFindingConfidence
        }
        self.category = category
        self.severity = severity
        self.confidence = confidence
    }
}

/// 内容审核结论。
public enum V2ContentReviewVerdict: Equatable, Sendable {
    /// 无需处理。
    case clear
    /// 需要人工复核，附带发现内容。
    case reviewRequired(V2ContentReviewFinding)
    /// 判定违规，附带发现内容。
    case violation(V2ContentReviewFinding)
}

/// 内容审核能力。
public protocol V2ContentReviewing: Sendable {
    /// 审核一条消息。
    ///
    /// - Parameter input: 审核输入。
    /// - Returns: 审核结论。
    /// - Throws: 提供方失败时抛出。
    func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict
}

/// 小型确定性部署闸门。
///
/// 生产环境的 OCR、图像、视频或 AI 提供方实现 ``V2ContentReviewing``；
/// 该评估器仍可作为廉价且可审计的第一道处理，并适用于本地环境。
public struct V2ConfiguredContentReviewer: V2ContentReviewing {
    private let violatingTerms: [String]
    private let reviewTerms: [String]

    /// 以违规词与待复核词列表构造评估器。
    ///
    /// - Parameters:
    ///   - violatingTerms: 判定违规的词列表。
    ///   - reviewTerms: 需要人工复核的词列表。
    public init(violatingTerms: [String] = [], reviewTerms: [String] = []) {
        self.violatingTerms = violatingTerms.map(Self.normalize).filter { !$0.isEmpty }
        self.reviewTerms = reviewTerms.map(Self.normalize).filter { !$0.isEmpty }
    }

    /// 按配置词表审核消息正文。
    ///
    /// - Parameter input: 审核输入。
    /// - Returns: 命中违规词时判定违规，命中待复核词时要求人工复核，否则判定无需处理。
    /// - Throws: 评估过程失败时抛出。
    public func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        let text = Self.normalize(input.text)
        if violatingTerms.contains(where: text.contains) {
            return try .violation(.init(category: "configured_policy", severity: 4, confidence: 1))
        }
        if reviewTerms.contains(where: text.contains) {
            return try .reviewRequired(.init(category: "configured_policy", severity: 2, confidence: 1))
        }
        // 恶意软件扫描结果出来前，媒体已禁止被引用。
        // 媒体语义或 OCR 适配器可稍后给出结论。
        return .clear
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}

public struct V2ContentReviewLease: Sendable {
    public let input: V2ContentReviewInput
    public let claimToken: UUID
    public let attempt: Int
    public let stagedViolation: V2ContentReviewFinding?
    public init(
        input: V2ContentReviewInput,
        claimToken: UUID,
        attempt: Int = 1,
        stagedViolation: V2ContentReviewFinding? = nil
    ) {
        precondition(attempt > 0)
        self.input = input
        self.claimToken = claimToken
        self.attempt = attempt
        self.stagedViolation = stagedViolation
    }
}

public enum V2ContentReviewLeaseValidation: Equatable, Sendable {
    case current
    case superseded
    case lostLease
}

/// 内容审核的持久化能力。
public protocol V2ContentReviewStore: Sendable {
    /// 认领一批待审核任务。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的审核租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2ContentReviewLease]

    /// 在缓慢的提供方调用之后原子地续期同一份认领。
    ///
    /// 更新后的编辑或撤回会把该任务判定为被取代；若认领令牌已被他人夺走，则视为丢失认领，
    /// 且绝不能改动新工作器的任务。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - now: 本次校验时刻。
    ///   - leaseDuration: 新的租约时长秒数。
    /// - Returns: 校验结论。
    /// - Throws: 持久化失败时抛出。
    func validateAndRenew(_ lease: V2ContentReviewLease, now: Date, leaseDuration: TimeInterval) async throws -> V2ContentReviewLeaseValidation

    /// 仅在该工作器仍持有认领时原子地关闭任务。
    ///
    /// 若期间已被并发重新认领则返回 `false`，避免旧工作器报告一个并非由它持久化的决定。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - verdict: 审核结论。
    ///   - now: 完成时刻。
    /// - Returns: 关闭生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func resolve(_ lease: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now: Date) async throws -> Bool

    /// 在权威审核副作用之前先持久化有界的违规发现。
    ///
    /// 这样在崩溃后被重新认领的租约可以继续同一决定，
    /// 无需让非确定性提供方重新生成已经丢失的证据。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - finding: 违规发现。
    /// - Returns: 记录生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func stageViolation(_ lease: V2ContentReviewLease, finding: V2ContentReviewFinding) async throws -> Bool

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次审核租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleRetry(_ lease: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 单轮内容审核统计。
public struct V2ContentReviewReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 已给出结论的数量。
    public let resolvedCount: Int
    /// 已执行屏蔽的数量。
    public let redactedCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
}

/// 只有可信安全服务的房间能力可应用审核结论。
/// 任务认领、提供方调用和重试簿记仍由工作器负责。
public protocol V2ContentReviewSafetyApplying: Sendable {
    func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome
}

extension V2TrustedSafetyModerationService: V2ContentReviewSafetyApplying {}

/// 已定义类型的 D2 可信安全命令的生产适配器。
/// 入站服务角色检查与房间轮次负责授权和完整激活围栏；
/// 传输失败会向外传播，供持久化任务重试。
public struct V2RoomContentReviewSafetyApplicator: V2ContentReviewSafetyApplying {
    private let invoke: @Sendable (V2RoomRequest, ContinuousClock.Instant) async throws -> V2RoomResponse
    private let callTimeout: Duration

    /// 组合层提供服务主体的 RoomRef 调用。
    /// 此模块有意不依赖 IMV2ActorRuntime。
    public init(callTimeout: Duration = .seconds(10),
                invoke: @escaping @Sendable (V2RoomRequest, ContinuousClock.Instant) async throws -> V2RoomResponse) {
        precondition(callTimeout > .zero)
        self.invoke = invoke
        self.callTimeout = callTimeout
    }

    public func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome {
        let response = try await invoke(.administration(.trustedSafety(.init(request))),
            ContinuousClock.now.advanced(by: callTimeout))
        guard case .administration(.trustedSafety(let outcome)) = response else {
            throw V2ContentReviewWorkerError.dispositionNotApplied
        }
        return try outcome.domain()
    }
}

/// 持久化且带租约栅栏的审核工作器。
///
/// 安全屏蔽使用稳定的消息标识作为审核操作标识，因此「已完成屏蔽但尚未完成任务」时的崩溃
/// 会幂等重试，而不会产生第二条事件。最新内容修订校验则阻止旧评估作用于已被编辑的消息。
public struct V2ContentReviewWorker: Sendable {
    private let store: any V2ContentReviewStore
    private let reviewer: any V2ContentReviewing
    private let moderation: any V2ContentReviewSafetyApplying
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(store: any V2ContentReviewStore, reviewer: any V2ContentReviewing, moderation: any V2ContentReviewSafetyApplying, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration.isFinite, leaseDuration > 0 else { throw V2ContentReviewWorkerError.invalidLeaseDuration }
        self.store = store
        self.reviewer = reviewer
        self.moderation = moderation
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2ContentReviewReport {
        guard limit > 0 else { throw V2ContentReviewWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var resolved = 0
        var redacted = 0
        var released = 0
        var retryFailure: (any Error)?
        for lease in leases {
            do {
                let verdict: V2ContentReviewVerdict
                if let stagedViolation = lease.stagedViolation {
                    verdict = .violation(stagedViolation)
                } else {
                    verdict = try await reviewer.review(lease.input)
                }
                guard try await validate(lease) else {
                    resolved += 1
                    continue
                }
                var appliedRedaction = false
                if case .violation(let finding) = verdict {
                    if lease.stagedViolation == nil,
                       try await store.stageViolation(lease, finding: finding) == false {
                        resolved += 1
                        continue
                    }
                    let operationID = try ModerationOperationID(lease.input.messageID.rawValue)
                    let request = try V2TrustedSafetyModeration(
                        roomID: lease.input.roomID,
                        operationID: operationID,
                        action: .redactMessage,
                        messageID: lease.input.messageID,
                        expectedMessageRevision: lease.input.contentRevision,
                        reasonCode: .init("content_policy_violation")
                    )
                    let outcome = try await moderation.apply(request)
                    switch outcome {
                    case .applied, .idempotent:
                        // 权威事务已对精确审核修订设置围栏。
                        // 它自身的墓碑不能让下方校验误以为此任务被无关的后续撤回取代。
                        appliedRedaction = true
                    case .messageAlreadyRedacted:
                        // 此不透明结果也可能表示修订冲突。
                        // 重新检查原始修订，防止过期证据关闭较新编辑的任务。
                        guard try await validate(lease) else {
                            resolved += 1
                            continue
                        }
                    case .idempotencyConflict, .targetNotMember, .actionAlreadyInDesiredState, .rateLimited, .unavailable:
                        throw V2ContentReviewWorkerError.dispositionNotApplied
                    }
                }
                let didResolve = try await store.resolve(lease, verdict: verdict, now: now())
                if appliedRedaction, didResolve { redacted += 1 }
                resolved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failureTime = now()
                let disposition = retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: failureTime,
                    kind: v2DurableWorkFailureKind(for: error)
                )
                do {
                    if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                    released += 1
                } catch {
                    // 继续处理有界批次，但不能将失败的持久化操作
                    // 报告为已成功释放租约。
                    retryFailure = retryFailure ?? error
                }
            }
        }
        if let retryFailure { throw retryFailure }
        return .init(claimedCount: leases.count, resolvedCount: resolved, redactedCount: redacted, releasedCount: released)
    }

    private func validate(_ lease: V2ContentReviewLease) async throws -> Bool {
        switch try await store.validateAndRenew(lease, now: now(), leaseDuration: leaseDuration) {
        case .current:
            true
        case .superseded, .lostLease:
            false
        }
    }
}

public enum V2ContentReviewWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
    case invalidFindingCategory
    case invalidFindingSeverity
    case invalidFindingConfidence
    case dispositionNotApplied
}
