import Foundation
import IMV2Core

/// 敏感的持有者凭据材料只出现在协调器通道中，绝不进入所有者命令。
public struct V2ActorInviteSecretWire: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { "<redacted-group-invite-secret>" }
    public var debugDescription: String { description }
}
/// 持有者密钥的 SHA-256 摘要；其类型可防止与密钥本身混用。
public struct V2ActorInviteTokenDigestWire: Codable, Equatable, Sendable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

public struct V2ActorCreateGroupInviteWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupInviteOperationID
    public let lifetime: TimeInterval
    public let maximumApprovedUses: Int
    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, lifetime: TimeInterval, maximumApprovedUses: Int) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.lifetime = lifetime; self.maximumApprovedUses = maximumApprovedUses
    }
}
public struct V2ActorRevokeGroupInviteWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupInviteOperationID
    public let inviteID: GroupInviteID
    public init(roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, inviteID: GroupInviteID) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID; self.inviteID = inviteID
    }
}
public struct V2ActorDecideGroupJoinWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let requestID: GroupJoinRequestID
    public let reviewerUserID: UserID
    public let operationID: GroupJoinDecisionOperationID
    public let decision: V2GroupJoinDecision
    public init(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) {
        self.roomID = roomID; self.requestID = requestID; self.reviewerUserID = reviewerUserID
        self.operationID = operationID; self.decision = decision
    }
}
public struct V2ActorCancelGroupJoinWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let requestID: GroupJoinRequestID
    public let applicantUserID: UserID
    public init(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID) {
        self.roomID = roomID; self.requestID = requestID; self.applicantUserID = applicantUserID
    }
}
public enum V2RoomInvitationOperationIdentity: Equatable, Sendable {
    case invite(GroupInviteOperationID)
    case decision(GroupJoinDecisionOperationID)
    case submission(GroupJoinRequestOperationID, generation: Int64)
}
public enum V2RoomInvitationCommand: Codable, Equatable, Sendable {
    case create(V2ActorCreateGroupInviteWire)
    case commitCreation(V2ActorInviteCreatePersistenceWire)
    case revoke(V2ActorRevokeGroupInviteWire)
    case decide(V2ActorDecideGroupJoinWire)
    case cancel(V2ActorCancelGroupJoinWire)
    case submitReserved(V2ActorGroupJoinQuotaIntentWire)
    public var roomID: RoomID {
        switch self {
        case .create(let v): v.roomID
        case .commitCreation(let v): v.roomID
        case .revoke(let v): v.roomID
        case .decide(let v): v.roomID
        case .cancel(let v): v.roomID
        case .submitReserved(let v): v.roomID
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .create(let v): v.actorUserID
        case .commitCreation(let v): v.actorUserID
        case .revoke(let v): v.actorUserID
        case .decide(let v): v.reviewerUserID
        case .cancel(let v): v.applicantUserID
        case .submitReserved(let v): v.applicantUserID
        }
    }
    public var stableOperationIdentity: V2RoomInvitationOperationIdentity? {
        switch self {
        case .create(let v): .invite(v.operationID)
        case .commitCreation(let v): .invite(v.operationID)
        case .revoke(let v): .invite(v.operationID)
        case .decide(let v): .decision(v.operationID)
        case .cancel: nil
        case .submitReserved(let v): .submission(v.operationID, generation: v.generation)
        }
    }
    public var retryPolicy: V2RoomReplayPolicy {
        switch self {
        case .cancel: .noAutomaticRetry
        case .create, .commitCreation, .revoke, .decide, .submitReserved: .durableIdempotent
        }
    }
}
public struct V2ActorActiveGroupInvitesQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public init(roomID: RoomID, actorUserID: UserID) { self.roomID = roomID; self.actorUserID = actorUserID }
}
public struct V2ActorPendingGroupJoinsQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let reviewerUserID: UserID
    public let cursor: String?
    public let pageSize: Int
    public init(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int) {
        self.roomID = roomID; self.reviewerUserID = reviewerUserID; self.cursor = cursor; self.pageSize = pageSize
    }
}
/// 仅在协调器将摘要解析到此房间并确认就绪后调用。
public struct V2ActorResolvedInvitePreviewQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let inviteID: GroupInviteID
    public let applicantUserID: UserID
    public let tokenDigest: V2ActorInviteTokenDigestWire
    public init(roomID: RoomID, inviteID: GroupInviteID, applicantUserID: UserID, tokenDigest: V2ActorInviteTokenDigestWire) {
        self.roomID = roomID; self.inviteID = inviteID; self.applicantUserID = applicantUserID; self.tokenDigest = tokenDigest
    }
}
public enum V2RoomInvitationQuery: Codable, Equatable, Sendable {
    case active(V2ActorActiveGroupInvitesQueryWire)
    case pending(V2ActorPendingGroupJoinsQueryWire)
    case resolvedPreview(V2ActorResolvedInvitePreviewQueryWire)
    case preflightCreation(V2ActorInviteCreatePersistenceWire)
    case reservedSubmissionResponse(V2ActorReservedSubmissionResponseQueryWire)
    public var roomID: RoomID {
        switch self {
        case .active(let v): v.roomID
        case .pending(let v): v.roomID
        case .resolvedPreview(let v): v.roomID
        case .preflightCreation(let v): v.roomID
        case .reservedSubmissionResponse(let v): v.intent.roomID
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .active(let v): v.actorUserID
        case .pending(let v): v.reviewerUserID
        case .resolvedPreview(let v): v.applicantUserID
        case .preflightCreation(let v): v.actorUserID
        case .reservedSubmissionResponse(let v): v.intent.applicantUserID
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}

/// 面向网关的未知房间操作仍由控制协调器处理。
public struct V2ActorInvitePreviewBySecretWire: Codable, Equatable, Sendable {
    public let applicantUserID: UserID
    public let secret: V2ActorInviteSecretWire
    public init(applicantUserID: UserID, secret: V2ActorInviteSecretWire) { self.applicantUserID = applicantUserID; self.secret = secret }
}
public struct V2ActorSubmitGroupJoinWire: Codable, Equatable, Sendable {
    public let applicantUserID: UserID
    public let operationID: GroupJoinRequestOperationID
    public let secret: V2ActorInviteSecretWire
    public let note: String?
    public init(applicantUserID: UserID, operationID: GroupJoinRequestOperationID, secret: V2ActorInviteSecretWire, note: String?) {
        self.applicantUserID = applicantUserID; self.operationID = operationID; self.secret = secret; self.note = note
    }
}
public enum V2ActorInvitationCoordinatorQuery: Codable, Equatable, Sendable {
    case previewBySecret(V2ActorInvitePreviewBySecretWire)
    case resolveDigest(V2ActorInviteTokenDigestWire)
    case readyInvites(V2ActorReadyInvitesQueryWire)
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}
public enum V2ActorInvitationCoordinatorCommand: Codable, Equatable, Sendable {
    case submitBySecret(V2ActorSubmitGroupJoinWire)
    case prepareCreation(V2ActorInviteCreatePersistenceWire)
    case finalizeCreation(V2ActorInviteCreationIntentWire)
    public var stableOperationIdentity: V2ActorInvitationCoordinatorOperationIdentity {
        switch self {
        case .submitBySecret(let v): .submission(v.operationID)
        case .prepareCreation(let v): .invite(v.operationID)
        case .finalizeCreation(let v): .invite(v.request.operationID)
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}
public enum V2ActorInvitationCoordinatorOperationIdentity: Equatable, Sendable {
    case submission(GroupJoinRequestOperationID)
    case invite(GroupInviteOperationID)
}
public struct V2ActorReadyInvitesQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let inviteIDs: [GroupInviteID]
    public init(roomID: RoomID, inviteIDs: [GroupInviteID]) { self.roomID = roomID; self.inviteIDs = inviteIDs }
}

public struct V2ActorInvitationPublicIdentityWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let handle: String
    public let displayName: String
    public let accountKind: V2AccountKind
    public init(userID: UserID, handle: String, displayName: String, accountKind: V2AccountKind) {
        self.userID = userID; self.handle = handle; self.displayName = displayName; self.accountKind = accountKind
    }
}
public struct V2ActorGroupInviteLinkWire: Codable, Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let secret: V2ActorInviteSecretWire
    public let state: V2GroupInviteState
    public let expiresAt: Date
    public let maximumApprovedUses: Int
    public let approvedUseCount: Int
    public let createdAt: Date
    public init(inviteID: GroupInviteID, roomID: RoomID, roomTitle: String, secret: V2ActorInviteSecretWire, state: V2GroupInviteState, expiresAt: Date, maximumApprovedUses: Int, approvedUseCount: Int, createdAt: Date) {
        self.inviteID = inviteID; self.roomID = roomID; self.roomTitle = roomTitle; self.secret = secret
        self.state = state; self.expiresAt = expiresAt; self.maximumApprovedUses = maximumApprovedUses
        self.approvedUseCount = approvedUseCount; self.createdAt = createdAt
    }
}
public struct V2ActorGroupInvitePreviewWire: Codable, Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let expiresAt: Date
    public let requestState: V2GroupJoinRequestState?
    public let requestID: GroupJoinRequestID?
    public let isAlreadyMember: Bool
    public init(inviteID: GroupInviteID, roomID: RoomID, roomTitle: String, expiresAt: Date, requestState: V2GroupJoinRequestState?, requestID: GroupJoinRequestID?, isAlreadyMember: Bool) {
        self.inviteID = inviteID; self.roomID = roomID; self.roomTitle = roomTitle; self.expiresAt = expiresAt
        self.requestState = requestState; self.requestID = requestID; self.isAlreadyMember = isAlreadyMember
    }
}
public struct V2ActorGroupJoinRequestWire: Codable, Equatable, Sendable {
    public let requestID: GroupJoinRequestID
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let applicant: V2ActorInvitationPublicIdentityWire
    public let note: String?
    public let state: V2GroupJoinRequestState
    public let resumableDecisionOperationID: GroupJoinDecisionOperationID?
    public let createdAt: Date
    public let decidedAt: Date?
    public init(requestID: GroupJoinRequestID, inviteID: GroupInviteID, roomID: RoomID, applicant: V2ActorInvitationPublicIdentityWire, note: String?, state: V2GroupJoinRequestState, resumableDecisionOperationID: GroupJoinDecisionOperationID?, createdAt: Date, decidedAt: Date?) {
        self.requestID = requestID; self.inviteID = inviteID; self.roomID = roomID; self.applicant = applicant
        self.note = note; self.state = state; self.resumableDecisionOperationID = resumableDecisionOperationID
        self.createdAt = createdAt; self.decidedAt = decidedAt
    }
}
public struct V2ActorGroupJoinRequestPageWire: Codable, Equatable, Sendable {
    public let requests: [V2ActorGroupJoinRequestWire]
    public let nextCursor: String?
    public init(requests: [V2ActorGroupJoinRequestWire], nextCursor: String?) {
        self.requests = requests; self.nextCursor = nextCursor
    }
}
public enum V2ActorGroupInvitePreviewPersistenceOutcomeWire: Codable, Equatable, Sendable {
    case available(V2ActorGroupInvitePreviewWire)
    case unavailable
}
public enum V2ActorGroupJoinSubmissionOutcomeWire: Codable, Equatable, Sendable {
    case submitted(V2ActorGroupJoinRequestRecordWire)
    case alreadyPending(V2ActorGroupJoinRequestRecordWire)
    case alreadyMember(V2ActorGroupInvitePreviewWire)
    case rejected(V2ActorGroupJoinRequestRecordWire)
    case cancelled(V2ActorGroupJoinRequestRecordWire)
    case unavailable
    case rateLimited
}
public enum V2ActorGroupJoinDecisionOutcomeWire: Codable, Equatable, Sendable {
    case approved(V2ActorGroupJoinRequestWire)
    case rejected(V2ActorGroupJoinRequestWire)
    case alreadyDecided(V2ActorGroupJoinRequestWire)
    case conflict
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
}
public enum V2RoomInvitationResult: Codable, Equatable, Sendable {
    case failure(V2ActorInvitationErrorWire)
    case created(V2ActorGroupInviteLinkWire)
    case createdStored(V2ActorStoredGroupInviteWire)
    case active([V2ActorGroupInviteLinkWire])
    case activeStored([V2ActorStoredGroupInviteWire])
    case revoked
    case preview(V2ActorGroupInvitePreviewWire?)
    case resolvedPreview(V2ActorGroupInvitePreviewPersistenceOutcomeWire)
    case pending(V2ActorGroupJoinRequestPageWire)
    case pendingRecords(V2ActorGroupJoinRequestRecordPageWire)
    case decided(V2ActorGroupJoinDecisionOutcomeWire)
    case approval(V2ActorGroupJoinApprovalPersistenceOutcomeWire)
    case rejection(V2ActorGroupJoinDecisionPreparationOutcomeWire)
    case cancelled(V2ActorGroupJoinRequestWire)
    case cancelledRecord(V2ActorGroupJoinRequestRecordWire)
    case reservedSubmission(V2ActorGroupJoinOwnerSubmissionWire)
    case preflightStored(V2ActorStoredGroupInviteWire?)
    case submission(V2ActorGroupJoinSubmissionOutcomeWire)
}
public enum V2ActorInvitationCoordinatorResult: Codable, Equatable, Sendable {
    case preview(V2ActorGroupInvitePreviewWire?)
    case submission(V2ActorGroupJoinSubmissionOutcomeWire)
    case prepared(V2ActorInviteCreationIntentWire)
    case finalized
    case location(V2ActorInviteLocationWire?)
    case readyInvites([GroupInviteID])
}
public enum V2ActorInvitationErrorWire: String, Codable, Error, Equatable, Sendable {
    case invalidConfiguration, invalidRequest, roomNotFound, inviteNotFound, requestNotFound
    case permissionDenied, rateLimited, conflict, creationExpired, ownerChanged, corruptPersistenceState
    case invalidSecret, invalidLink, invalidPreview, invalidGroupJoinRequest
    case directoryConflict, ownerResultMismatch
}

/// 跨分片邀请创建回执使用精确的 PostgreSQL 时间戳绑定。
public struct V2ActorInvitePersistedTimesWire: Codable, Equatable, Sendable {
    public let createdAtMicroseconds: Int64
    public let expiresAtMicroseconds: Int64
    public init(createdAtMicroseconds: Int64, expiresAtMicroseconds: Int64) {
        self.createdAtMicroseconds = createdAtMicroseconds
        self.expiresAtMicroseconds = expiresAtMicroseconds
    }
}

/// 传给所有者的固定控制意图；网关不能选择其中任何初始值。
public struct V2ActorInviteCreatePersistenceWire: Codable, Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: GroupInviteOperationID
    public let tokenDigest: V2ActorInviteTokenDigestWire
    public let requestedLifetimeSeconds: Int
    public let expiresAt: Date
    public let maximumApprovedUses: Int
    public let maximumActiveInvitesPerRoom: Int
    public let createdAt: Date
    public let evaluatedAt: Date
    public let persistedTimes: V2ActorInvitePersistedTimesWire?
    public init(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, tokenDigest: V2ActorInviteTokenDigestWire, requestedLifetimeSeconds: Int, expiresAt: Date, maximumApprovedUses: Int, maximumActiveInvitesPerRoom: Int, createdAt: Date, evaluatedAt: Date, persistedTimes: V2ActorInvitePersistedTimesWire? = nil) {
        self.inviteID = inviteID; self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.tokenDigest = tokenDigest; self.requestedLifetimeSeconds = requestedLifetimeSeconds; self.expiresAt = expiresAt
        self.maximumApprovedUses = maximumApprovedUses; self.maximumActiveInvitesPerRoom = maximumActiveInvitesPerRoom
        self.createdAt = createdAt; self.evaluatedAt = evaluatedAt; self.persistedTimes = persistedTimes
    }
}
public struct V2ActorInviteCreationIntentWire: Codable, Equatable, Sendable {
    public let request: V2ActorInviteCreatePersistenceWire
    public let isReady: Bool
    public init(request: V2ActorInviteCreatePersistenceWire, isReady: Bool) { self.request = request; self.isReady = isReady }
}
public struct V2ActorInviteLocationWire: Codable, Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public init(inviteID: GroupInviteID, roomID: RoomID) { self.inviteID = inviteID; self.roomID = roomID }
}
public struct V2ActorStoredGroupInviteWire: Codable, Equatable, Sendable {
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
    public let persistedTimes: V2ActorInvitePersistedTimesWire?
    public init(inviteID: GroupInviteID, roomID: RoomID, roomTitle: String, createdByUserID: UserID, creationOperationID: GroupInviteOperationID, state: V2GroupInviteState, expiresAt: Date, maximumApprovedUses: Int, approvedUseCount: Int, createdAt: Date, persistedTimes: V2ActorInvitePersistedTimesWire? = nil) {
        self.inviteID = inviteID; self.roomID = roomID; self.roomTitle = roomTitle; self.createdByUserID = createdByUserID
        self.creationOperationID = creationOperationID; self.state = state; self.expiresAt = expiresAt
        self.maximumApprovedUses = maximumApprovedUses; self.approvedUseCount = approvedUseCount; self.createdAt = createdAt; self.persistedTimes = persistedTimes
    }
}
/// 构造此所有者输入前，已完成配额预留和摘要解析。
public struct V2ActorJoinSubmissionPersistenceWire: Codable, Equatable, Sendable {
    public let requestID: GroupJoinRequestID
    public let applicantUserID: UserID
    public let operationID: GroupJoinRequestOperationID
    public let tokenDigest: V2ActorInviteTokenDigestWire
    public let note: String?
    public let createdAt: Date
    public let maximumPendingRequestsPerApplicant: Int
    public let maximumPendingRequestsPerInvite: Int
    public init(requestID: GroupJoinRequestID, applicantUserID: UserID, operationID: GroupJoinRequestOperationID, tokenDigest: V2ActorInviteTokenDigestWire, note: String?, createdAt: Date, maximumPendingRequestsPerApplicant: Int, maximumPendingRequestsPerInvite: Int) {
        self.requestID = requestID; self.applicantUserID = applicantUserID; self.operationID = operationID
        self.tokenDigest = tokenDigest; self.note = note; self.createdAt = createdAt
        self.maximumPendingRequestsPerApplicant = maximumPendingRequestsPerApplicant
        self.maximumPendingRequestsPerInvite = maximumPendingRequestsPerInvite
    }
}
public struct V2ActorGroupJoinRequestRecordWire: Codable, Equatable, Sendable {
    public let requestID: GroupJoinRequestID
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let applicant: V2ActorInvitationPublicIdentityWire
    public let note: String?
    public let state: V2GroupJoinRequestState
    public let decisionOperationID: GroupJoinDecisionOperationID?
    public let decidedByUserID: UserID?
    public let createdAt: Date
    public let decidedAt: Date?
    public init(requestID: GroupJoinRequestID, inviteID: GroupInviteID, roomID: RoomID, applicant: V2ActorInvitationPublicIdentityWire, note: String?, state: V2GroupJoinRequestState, decisionOperationID: GroupJoinDecisionOperationID?, decidedByUserID: UserID?, createdAt: Date, decidedAt: Date?) {
        self.requestID = requestID; self.inviteID = inviteID; self.roomID = roomID; self.applicant = applicant
        self.note = note; self.state = state; self.decisionOperationID = decisionOperationID
        self.decidedByUserID = decidedByUserID; self.createdAt = createdAt; self.decidedAt = decidedAt
    }
}
public struct V2ActorGroupJoinRequestRecordPageWire: Codable, Equatable, Sendable {
    public let requests: [V2ActorGroupJoinRequestRecordWire]
    public let nextCursor: String?
    public init(requests: [V2ActorGroupJoinRequestRecordWire], nextCursor: String?) { self.requests = requests; self.nextCursor = nextCursor }
}
public enum V2ActorGroupJoinApprovalPersistenceOutcomeWire: Codable, Equatable, Sendable {
    case approved(V2ActorGroupJoinRequestRecordWire)
    case alreadyDecided(V2ActorGroupJoinRequestRecordWire)
    case conflict, memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
}
public enum V2ActorGroupJoinDecisionPreparationOutcomeWire: Codable, Equatable, Sendable {
    case rejected(V2ActorGroupJoinRequestRecordWire)
    case alreadyApproved(V2ActorGroupJoinRequestRecordWire)
    case alreadyRejected(V2ActorGroupJoinRequestRecordWire)
    case decisionConflict, inviteExhausted
}

/// 控制侧预留的全局配额意图只发送给已解析出的房间所有者。
public enum V2ActorGroupJoinQuotaPhaseWire: String, Codable, Equatable, Sendable {
    case held, tracking, denied, terminal
}
public enum V2ActorGroupJoinQuotaOutcomeWire: String, Codable, Equatable, Sendable {
    case pending, approved, rejected, cancelled
    case alreadyMember = "already_member"
    case unavailable, rateLimited = "rate_limited", permissionDenied = "permission_denied"
}
public struct V2ActorGroupJoinQuotaIntentWire: Codable, Equatable, Sendable {
    public let applicantUserID: UserID
    public let operationID: GroupJoinRequestOperationID
    public let requestID: GroupJoinRequestID
    public let roomID: RoomID
    public let inviteID: GroupInviteID
    public let tokenDigest: V2ActorInviteTokenDigestWire
    public let note: String?
    public let maximumPendingPerInvite: Int
    public let generation: Int64
    public let phase: V2ActorGroupJoinQuotaPhaseWire
    public let outcome: V2ActorGroupJoinQuotaOutcomeWire?
    public let targetRequestID: GroupJoinRequestID?
    public let createdAt: Date
    public let attemptCreatedAt: Date
    public let updatedAt: Date
    public let nextCheckAt: Date
    public let leaseToken: UUID?
    public let leaseUntil: Date?
    public let attemptCount: Int64
    public init(applicantUserID: UserID, operationID: GroupJoinRequestOperationID, requestID: GroupJoinRequestID,
                roomID: RoomID, inviteID: GroupInviteID, tokenDigest: V2ActorInviteTokenDigestWire,
                note: String?, maximumPendingPerInvite: Int, generation: Int64,
                phase: V2ActorGroupJoinQuotaPhaseWire, outcome: V2ActorGroupJoinQuotaOutcomeWire?,
                targetRequestID: GroupJoinRequestID?, createdAt: Date, attemptCreatedAt: Date,
                updatedAt: Date, nextCheckAt: Date, leaseToken: UUID?, leaseUntil: Date?, attemptCount: Int64) {
        self.applicantUserID = applicantUserID; self.operationID = operationID; self.requestID = requestID
        self.roomID = roomID; self.inviteID = inviteID; self.tokenDigest = tokenDigest; self.note = note
        self.maximumPendingPerInvite = maximumPendingPerInvite; self.generation = generation
        self.phase = phase; self.outcome = outcome; self.targetRequestID = targetRequestID
        self.createdAt = createdAt; self.attemptCreatedAt = attemptCreatedAt; self.updatedAt = updatedAt
        self.nextCheckAt = nextCheckAt; self.leaseToken = leaseToken; self.leaseUntil = leaseUntil
        self.attemptCount = attemptCount
    }
}
public struct V2ActorGroupJoinOwnerSubmissionWire: Codable, Equatable, Sendable {
    public let outcome: V2ActorGroupJoinQuotaOutcomeWire
    public let targetRequestID: GroupJoinRequestID?
    public let wasInserted: Bool
    public init(outcome: V2ActorGroupJoinQuotaOutcomeWire, targetRequestID: GroupJoinRequestID?, wasInserted: Bool) {
        self.outcome = outcome; self.targetRequestID = targetRequestID; self.wasInserted = wasInserted
    }
}
public struct V2ActorReservedSubmissionResponseQueryWire: Codable, Equatable, Sendable {
    public let intent: V2ActorGroupJoinQuotaIntentWire
    public let observed: V2ActorGroupJoinOwnerSubmissionWire
    public init(intent: V2ActorGroupJoinQuotaIntentWire, observed: V2ActorGroupJoinOwnerSubmissionWire) {
        self.intent = intent
        self.observed = observed
    }
}
