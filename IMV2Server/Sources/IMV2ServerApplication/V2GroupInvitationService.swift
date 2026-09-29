import IMV2ServerContracts
import Crypto
import Foundation
import IMV2Core

/// 群邀请的部署策略参数。
///
/// 各项上限用于约束邀请有效期、可用次数与单房间并发邀请量，
/// 以及单个申请人与单条邀请上允许的待处理申请数量。
public struct V2GroupInvitationPolicy: Equatable, Sendable {
    /// 标准策略：最短 5 分钟、最长 30 天。
    public static let standard = try! V2GroupInvitationPolicy()

    /// 邀请最短有效期秒数。
    public let minimumLifetime: TimeInterval
    /// 邀请最长有效期秒数。
    public let maximumLifetime: TimeInterval
    /// 单条邀请允许的最大审批通过次数。
    public let maximumApprovedUses: Int
    /// 单房间允许的活跃邀请上限。
    public let maximumActiveInvitesPerRoom: Int
    /// 单个申请人允许的待处理申请上限。
    public let maximumPendingRequestsPerApplicant: Int
    /// 单条邀请允许的待处理申请上限。
    public let maximumPendingRequestsPerInvite: Int

    /// 校验并保存邀请策略。
    ///
    /// - Parameters:
    ///   - minimumLifetime: 最短有效期，需大于零，默认 5 分钟。
    ///   - maximumLifetime: 最长有效期，需不小于最短有效期且可写入 `Int`，默认 30 天。
    ///   - maximumApprovedUses: 最大通过次数，需大于零，默认 1000。
    ///   - maximumActiveInvitesPerRoom: 活跃邀请上限，需大于零，默认 20。
    ///   - maximumPendingRequestsPerApplicant: 申请人待处理上限，需大于零，默认 20。
    ///   - maximumPendingRequestsPerInvite: 单邀请待处理上限，需大于零，默认 1000。
    /// - Throws: 任一取值不满足约束时抛出
    ///   ``V2GroupInvitationServiceError/invalidRequest``。
    public init(
        minimumLifetime: TimeInterval = 5 * 60,
        maximumLifetime: TimeInterval = 30 * 86_400,
        maximumApprovedUses: Int = 1_000,
        maximumActiveInvitesPerRoom: Int = 20,
        maximumPendingRequestsPerApplicant: Int = 20,
        maximumPendingRequestsPerInvite: Int = 1_000
    ) throws {
        guard minimumLifetime > 0,
              maximumLifetime >= minimumLifetime,
              Int(exactly: maximumLifetime.rounded(.towardZero)) != nil,
              maximumApprovedUses > 0,
              maximumActiveInvitesPerRoom > 0,
              maximumPendingRequestsPerApplicant > 0,
              maximumPendingRequestsPerInvite > 0
        else { throw V2GroupInvitationServiceError.invalidRequest }
        self.minimumLifetime = minimumLifetime
        self.maximumLifetime = maximumLifetime
        self.maximumApprovedUses = maximumApprovedUses
        self.maximumActiveInvitesPerRoom = maximumActiveInvitesPerRoom
        self.maximumPendingRequestsPerApplicant = maximumPendingRequestsPerApplicant
        self.maximumPendingRequestsPerInvite = maximumPendingRequestsPerInvite
    }
}

/// 由持久化操作标识派生可重试的 256 位邀请密钥的签发器。
///
/// 密钥永不离开账号服务；域分隔前缀确保该构造不能与其他 HMAC 用途互相替换。
public struct V2GroupInviteSecretIssuer: Sendable {
    private let key: SymmetricKey

    /// 以 Base64 密钥构造签发器。
    ///
    /// - Parameter value: Base64 编码的密钥，至少 32 字节。
    /// - Throws: 无法解码或长度不足时抛出
    ///   ``V2GroupInvitationServiceError/invalidConfiguration``。
    public init(base64EncodedKey value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GroupInvitationServiceError.invalidConfiguration
        }
        key = SymmetricKey(data: bytes)
    }

    /// 以原始密钥构造签发器。
    ///
    /// - Parameter rawKey: 密钥字节，至少 32 字节。
    /// - Throws: 长度不足时抛出
    ///   ``V2GroupInvitationServiceError/invalidConfiguration``。
    public init(rawKey: Data) throws {
        guard rawKey.count >= 32 else { throw V2GroupInvitationServiceError.invalidConfiguration }
        key = SymmetricKey(data: rawKey)
    }

    /// 为一次邀请操作派生密钥。
    ///
    /// 派生输入绑定发起者与操作标识，因此同一操作重试会得到相同密钥，
    /// 而不同操作之间互不相同。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起邀请的用户。
    ///   - operationID: 邀请操作标识。
    /// - Returns: URL 安全 Base64 编码的邀请密钥。
    /// - Throws: 密钥构造失败时抛出
    ///   ``V2GroupInvitationServiceError/invalidRequest``。
    public func secret(actorUserID: UserID, operationID: GroupInviteOperationID) throws -> V2GroupInviteSecret {
        let material = Data("im-v2-group-invite-v1\u{0}\(actorUserID.rawValue)\u{0}\(operationID.rawValue)".utf8)
        let bytes = Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try .init(encoded)
    }

    /// 计算邀请密钥的摘要。
    ///
    /// - Parameter secret: 邀请密钥。
    /// - Returns: 密钥明文的 SHA-256 摘要。
    public func digest(_ secret: V2GroupInviteSecret) -> Data {
        Data(SHA256.hash(data: Data(secret.rawValue.utf8)))
    }
}

public struct V2CreateGroupInviteRequest: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupInviteOperationID
    public let lifetime: TimeInterval
    public let maximumApprovedUses: Int

    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, lifetime: TimeInterval, maximumApprovedUses: Int) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.lifetime = lifetime
        self.maximumApprovedUses = maximumApprovedUses
    }
}

public struct V2SubmitGroupJoinRequest: Sendable {
    public let applicantUserID: UserID
    public let operationID: GroupJoinRequestOperationID
    public let secret: V2GroupInviteSecret
    public let note: String?

    public init(applicantUserID: UserID, operationID: GroupJoinRequestOperationID, secret: V2GroupInviteSecret, note: String?) {
        self.applicantUserID = applicantUserID
        self.operationID = operationID
        self.secret = secret
        self.note = note
    }
}

public struct V2DecideGroupJoinRequest: Sendable {
    public let roomID: RoomID
    public let requestID: GroupJoinRequestID
    public let reviewerUserID: UserID
    public let operationID: GroupJoinDecisionOperationID
    public let decision: V2GroupJoinDecision

    public init(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) {
        self.roomID = roomID
        self.requestID = requestID
        self.reviewerUserID = reviewerUserID
        self.operationID = operationID
        self.decision = decision
    }
}

public struct V2StoredGroupInvite: Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let createdByUserID: UserID
    public let creationOperationID: GroupInviteOperationID
    public let state: V2GroupInviteState
    public let expiresAt: Date
    public let maximumApprovedUses: Int
    public let approvedUseCount: Int
    public let createdAt: Date
    // 将所有者回执接入控制目录时，保留不可变的数据库绑定。
    // Date 只是其公开表示。
    package var persistedTimestamps: V2GroupInviteCreationTimestamps? = nil
    package init(inviteID: GroupInviteID, roomID: RoomID, roomTitle: String,
                 createdByUserID: UserID, creationOperationID: GroupInviteOperationID,
                 state: V2GroupInviteState, expiresAt: Date, maximumApprovedUses: Int,
                 approvedUseCount: Int, createdAt: Date,
                 persistedTimestamps: V2GroupInviteCreationTimestamps? = nil) {
        self.inviteID = inviteID; self.roomID = roomID; self.roomTitle = roomTitle
        self.createdByUserID = createdByUserID; self.creationOperationID = creationOperationID
        self.state = state; self.expiresAt = expiresAt; self.maximumApprovedUses = maximumApprovedUses
        self.approvedUseCount = approvedUseCount; self.createdAt = createdAt
        self.persistedTimestamps = persistedTimestamps
    }
}

public struct V2GroupInvitePreviewRecord: Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let expiresAt: Date
    public let requestState: V2GroupJoinRequestState?
    public let requestID: GroupJoinRequestID?
    public let isAlreadyMember: Bool
    package init(inviteID: GroupInviteID, roomID: RoomID, roomTitle: String, expiresAt: Date,
                 requestState: V2GroupJoinRequestState?, requestID: GroupJoinRequestID?, isAlreadyMember: Bool) {
        self.inviteID = inviteID; self.roomID = roomID; self.roomTitle = roomTitle
        self.expiresAt = expiresAt; self.requestState = requestState; self.requestID = requestID
        self.isAlreadyMember = isAlreadyMember
    }
}

public struct V2GroupJoinRequestRecord: Equatable, Sendable {
    public let requestID: GroupJoinRequestID
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let applicant: V2PublicIdentity
    public let note: String?
    public let state: V2GroupJoinRequestState
    public let decisionOperationID: GroupJoinDecisionOperationID?
    public let decidedByUserID: UserID?
    public let createdAt: Date
    public let decidedAt: Date?
    package init(requestID: GroupJoinRequestID, inviteID: GroupInviteID, roomID: RoomID,
                 applicant: V2PublicIdentity, note: String?, state: V2GroupJoinRequestState,
                 decisionOperationID: GroupJoinDecisionOperationID?, decidedByUserID: UserID?,
                 createdAt: Date, decidedAt: Date?) {
        self.requestID = requestID; self.inviteID = inviteID; self.roomID = roomID
        self.applicant = applicant; self.note = note; self.state = state
        self.decisionOperationID = decisionOperationID; self.decidedByUserID = decidedByUserID
        self.createdAt = createdAt; self.decidedAt = decidedAt
    }
}

public struct V2GroupJoinRequestRecordPage: Equatable, Sendable {
    public let requests: [V2GroupJoinRequestRecord]
    public let nextCursor: String?
    package init(requests: [V2GroupJoinRequestRecord], nextCursor: String?) {
        self.requests = requests; self.nextCursor = nextCursor
    }
}

public struct V2GroupInviteCreatePersistenceRequest: Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupInviteOperationID
    public let tokenDigest: Data
    public let requestedLifetimeSeconds: Int
    public let expiresAt: Date
    public let maximumApprovedUses: Int
    public let maximumActiveInvitesPerRoom: Int
    public let createdAt: Date
    /// 本次尝试的业务时刻。
    ///
    /// 它只影响本次评估，绝不会改变已经固定的原始有效期。
    public let evaluatedAt: Date
    package private(set) var persistedTimestamps: V2GroupInviteCreationTimestamps?

    public init(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, tokenDigest: Data, requestedLifetimeSeconds: Int, expiresAt: Date, maximumApprovedUses: Int, maximumActiveInvitesPerRoom: Int, createdAt: Date, evaluatedAt: Date? = nil) {
        self.inviteID = inviteID; self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.tokenDigest = tokenDigest; self.requestedLifetimeSeconds = requestedLifetimeSeconds
        self.expiresAt = expiresAt; self.maximumApprovedUses = maximumApprovedUses
        self.maximumActiveInvitesPerRoom = maximumActiveInvitesPerRoom; self.createdAt = createdAt
        self.evaluatedAt = evaluatedAt ?? createdAt
        self.persistedTimestamps = .init(createdAt: createdAt, expiresAt: expiresAt)
    }

    public func evaluated(at now: Date) -> Self {
        .init(inviteID: inviteID, roomID: roomID, actorUserID: actorUserID, operationID: operationID,
              tokenDigest: tokenDigest, requestedLifetimeSeconds: requestedLifetimeSeconds, expiresAt: expiresAt,
              maximumApprovedUses: maximumApprovedUses, maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom,
              createdAt: createdAt, evaluatedAt: now).preservingTimestamps(persistedTimestamps)
    }

    package func preservingTimestamps(_ timestamps: V2GroupInviteCreationTimestamps?) -> Self {
        var copy = self
        if let timestamps { copy.persistedTimestamps = timestamps }
        return copy
    }
}

package struct V2GroupInviteCreationTimestamps: Equatable, Sendable {
    package let createdAt: V2PersistenceTimestamp
    package let expiresAt: V2PersistenceTimestamp

    package init(createdAt: V2PersistenceTimestamp, expiresAt: V2PersistenceTimestamp) {
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    package init?(createdAt: Date, expiresAt: Date) {
        guard let created = try? V2PersistenceTimestamp(date: createdAt),
              let expires = try? V2PersistenceTimestamp(date: expiresAt) else { return nil }
        self.init(createdAt: created, expiresAt: expires)
    }
}

public struct V2GroupJoinSubmissionPersistenceRequest: Sendable {
    public let requestID: GroupJoinRequestID
    public let applicantUserID: UserID
    public let operationID: GroupJoinRequestOperationID
    public let tokenDigest: Data
    public let note: String?
    public let createdAt: Date
    public let maximumPendingRequestsPerApplicant: Int
    public let maximumPendingRequestsPerInvite: Int
    package init(requestID: GroupJoinRequestID, applicantUserID: UserID,
                 operationID: GroupJoinRequestOperationID, tokenDigest: Data, note: String?,
                 createdAt: Date, maximumPendingRequestsPerApplicant: Int,
                 maximumPendingRequestsPerInvite: Int) {
        self.requestID = requestID; self.applicantUserID = applicantUserID
        self.operationID = operationID; self.tokenDigest = tokenDigest; self.note = note
        self.createdAt = createdAt
        self.maximumPendingRequestsPerApplicant = maximumPendingRequestsPerApplicant
        self.maximumPendingRequestsPerInvite = maximumPendingRequestsPerInvite
    }
}

public enum V2GroupInvitePreviewPersistenceOutcome: Equatable, Sendable {
    case available(V2GroupInvitePreviewRecord)
    case unavailable
}

public enum V2GroupJoinSubmissionPersistenceOutcome: Equatable, Sendable {
    case submitted(V2GroupJoinRequestRecord)
    case alreadyPending(V2GroupJoinRequestRecord)
    case alreadyMember(V2GroupInvitePreviewRecord)
    case rejected(V2GroupJoinRequestRecord)
    case cancelled(V2GroupJoinRequestRecord)
    case unavailable
    case rateLimited
}

public enum V2GroupJoinDecisionPreparationOutcome: Equatable, Sendable {
    case rejected(V2GroupJoinRequestRecord)
    case alreadyApproved(V2GroupJoinRequestRecord)
    case alreadyRejected(V2GroupJoinRequestRecord)
    case decisionConflict
    case inviteExhausted
}

/// 群入群审批的持久化结果。
///
/// 审批与成员操作及其持久化结果同属一个归属事务；审批失败时申请保持待处理状态。
public enum V2GroupJoinApprovalPersistenceOutcome: Equatable, Sendable {
    /// 本次调用实际批准了申请。
    case approved(V2GroupJoinRequestRecord)
    /// 该申请此前已作出决定。
    case alreadyDecided(V2GroupJoinRequestRecord)
    /// 决策与当前状态冲突。
    case conflict
    /// 成员数量已达房间上限。
    case memberLimitReached
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入或存储当前不可用。
    case unavailable
}

public enum V2GroupJoinDecisionOutcome: Equatable, Sendable {
    case approved(V2GroupJoinRequest)
    case rejected(V2GroupJoinRequest)
    case alreadyDecided(V2GroupJoinRequest)
    case conflict
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
}

public enum V2GroupInvitationServiceError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case roomNotFound
    case inviteNotFound
    case requestNotFound
    case permissionDenied
    case rateLimited
    case conflict
    case creationExpired
    case ownerChanged
    case corruptPersistenceState
}
