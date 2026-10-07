import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2ActorInviteSecretWire {
    public init(domain: V2GroupInviteSecret) { self.init(rawValue: domain.rawValue) }
    public func toDomain() throws -> V2GroupInviteSecret { try .init(rawValue) }
}
extension V2ActorInviteTokenDigestWire {
    public func validatedBytes() throws -> Data {
        guard bytes.count == 32 else { throw V2GroupInvitationServiceError.invalidRequest }
        return bytes
    }
}
extension V2ActorCreateGroupInviteWire {
    public func toDomain() throws -> V2CreateGroupInviteRequest {
        guard lifetime.isFinite, lifetime > 0, maximumApprovedUses > 0 else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(roomID: roomID, actorUserID: actorUserID, operationID: operationID,
                     lifetime: lifetime, maximumApprovedUses: maximumApprovedUses)
    }
}
extension V2ActorDecideGroupJoinWire {
    public func toDomain() -> V2DecideGroupJoinRequest {
        .init(roomID: roomID, requestID: requestID, reviewerUserID: reviewerUserID,
              operationID: operationID, decision: decision)
    }
}
extension V2ActorSubmitGroupJoinWire {
    public func toDomain() throws -> V2SubmitGroupJoinRequest {
        guard note?.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count ?? 0 <= 500 else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(applicantUserID: applicantUserID, operationID: operationID,
                     secret: try secret.toDomain(), note: note)
    }
}
extension V2ActorPendingGroupJoinsQueryWire {
    public func validatedPageSize() throws -> Int {
        guard (1...100).contains(pageSize), cursor?.utf8.count ?? 0 <= 1024 else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        if let cursor {
            guard let uuid = roomID.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
            _ = try V2GroupJoinPageCursor.decode(cursor, roomID: uuid)
        }
        return pageSize
    }
}
extension V2ActorInvitationPublicIdentityWire {
    public init(domain: V2PublicIdentity) {
        self.init(userID: domain.userID, handle: domain.handle.rawValue,
                  displayName: domain.displayName, accountKind: domain.accountKind)
    }
    public func toDomain() throws -> V2PublicIdentity {
        let parsed = try V2PublicHandle(handle)
        guard parsed.rawValue == handle else { throw V2PublicIdentityValidationError.invalidHandle }
        let value = try V2PublicIdentity(userID: userID, handle: parsed,
                                         displayName: displayName, accountKind: accountKind)
        guard value.displayName == displayName else { throw V2PublicIdentityValidationError.invalidDisplayName }
        return value
    }
}
extension V2ActorGroupInviteLinkWire {
    public init(domain: V2GroupInviteLink) {
        self.init(inviteID: domain.inviteID, roomID: domain.roomID, roomTitle: domain.roomTitle,
                  secret: .init(domain: domain.secret), state: domain.state, expiresAt: domain.expiresAt,
                  maximumApprovedUses: domain.maximumApprovedUses, approvedUseCount: domain.approvedUseCount,
                  createdAt: domain.createdAt)
    }
    public func toDomain() throws -> V2GroupInviteLink {
        guard expiresAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970.isFinite else {
            throw V2GroupInvitationValidationError.invalidLink
        }
        let value = try V2GroupInviteLink(inviteID: inviteID, roomID: roomID, roomTitle: roomTitle,
                                           secret: secret.toDomain(), state: state, expiresAt: expiresAt,
                                           maximumApprovedUses: maximumApprovedUses,
                                           approvedUseCount: approvedUseCount, createdAt: createdAt)
        guard value.roomTitle == roomTitle else { throw V2GroupInvitationValidationError.invalidLink }
        return value
    }
}
extension V2ActorGroupInvitePreviewWire {
    public init(domain: V2GroupInvitePreview) {
        self.init(inviteID: domain.inviteID, roomID: domain.roomID, roomTitle: domain.roomTitle,
                  expiresAt: domain.expiresAt, requestState: domain.requestState,
                  requestID: domain.requestID, isAlreadyMember: domain.isAlreadyMember)
    }
    public init(record: V2GroupInvitePreviewRecord) {
        self.init(inviteID: record.inviteID, roomID: record.roomID, roomTitle: record.roomTitle,
                  expiresAt: record.expiresAt, requestState: record.requestState,
                  requestID: record.requestID, isAlreadyMember: record.isAlreadyMember)
    }
    public func toDomain() throws -> V2GroupInvitePreview {
        guard expiresAt.timeIntervalSince1970.isFinite else { throw V2GroupInvitationValidationError.invalidPreview }
        let value = try V2GroupInvitePreview(inviteID: inviteID, roomID: roomID, roomTitle: roomTitle,
                                              expiresAt: expiresAt, requestState: requestState,
                                              requestID: requestID, isAlreadyMember: isAlreadyMember)
        guard value.roomTitle == roomTitle else { throw V2GroupInvitationValidationError.invalidPreview }
        return value
    }
    public func toRecord() throws -> V2GroupInvitePreviewRecord {
        _ = try toDomain()
        return .init(inviteID: inviteID, roomID: roomID, roomTitle: roomTitle, expiresAt: expiresAt,
                     requestState: requestState, requestID: requestID, isAlreadyMember: isAlreadyMember)
    }
}
extension V2ActorGroupJoinRequestWire {
    public init(domain: V2GroupJoinRequest) {
        self.init(requestID: domain.requestID, inviteID: domain.inviteID, roomID: domain.roomID,
                  applicant: .init(domain: domain.applicant), note: domain.note, state: domain.state,
                  resumableDecisionOperationID: domain.resumableDecisionOperationID,
                  createdAt: domain.createdAt, decidedAt: domain.decidedAt)
    }
    public func toDomain() throws -> V2GroupJoinRequest {
        guard createdAt.timeIntervalSince1970.isFinite,
              decidedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw V2GroupInvitationValidationError.invalidRequest
        }
        let value = try V2GroupJoinRequest(requestID: requestID, inviteID: inviteID, roomID: roomID,
                                            applicant: applicant.toDomain(), note: note, state: state,
                                            resumableDecisionOperationID: resumableDecisionOperationID,
                                            createdAt: createdAt, decidedAt: decidedAt)
        guard value.note == note else { throw V2GroupInvitationValidationError.invalidRequest }
        return value
    }
}
extension V2ActorGroupJoinRequestPageWire {
    public init(domain: V2GroupJoinRequestPage) {
        self.init(requests: domain.requests.map(V2ActorGroupJoinRequestWire.init(domain:)), nextCursor: domain.nextCursor)
    }
    public func toDomain() throws -> V2GroupJoinRequestPage {
        guard requests.count <= 100, nextCursor?.utf8.count ?? 0 <= 4096 else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(requests: try requests.map { try $0.toDomain() }, nextCursor: nextCursor)
    }
}
extension V2ActorGroupJoinSubmissionOutcomeWire {
    public init(domain: V2GroupJoinSubmissionPersistenceOutcome) {
        switch domain {
        case .submitted(let v): self = .submitted(.init(record: v))
        case .alreadyPending(let v): self = .alreadyPending(.init(record: v))
        case .alreadyMember(let v): self = .alreadyMember(.init(record: v))
        case .rejected(let v): self = .rejected(.init(record: v))
        case .cancelled(let v): self = .cancelled(.init(record: v))
        case .unavailable: self = .unavailable
        case .rateLimited: self = .rateLimited
        }
    }
    public func toDomain() throws -> V2GroupJoinSubmissionPersistenceOutcome {
        switch self {
        case .submitted(let v): .submitted(try v.toRecord())
        case .alreadyPending(let v): .alreadyPending(try v.toRecord())
        case .alreadyMember(let v): .alreadyMember(try v.toRecord())
        case .rejected(let v): .rejected(try v.toRecord())
        case .cancelled(let v): .cancelled(try v.toRecord())
        case .unavailable: .unavailable
        case .rateLimited: .rateLimited
        }
    }
}
extension V2ActorGroupJoinDecisionOutcomeWire {
    public init(domain: V2GroupJoinDecisionOutcome) {
        switch domain {
        case .approved(let v): self = .approved(.init(domain: v))
        case .rejected(let v): self = .rejected(.init(domain: v))
        case .alreadyDecided(let v): self = .alreadyDecided(.init(domain: v))
        case .conflict: self = .conflict
        case .memberLimitReached: self = .memberLimitReached
        case .rateLimited(let seconds): self = .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: self = .unavailable
        }
    }
    public func toDomain() throws -> V2GroupJoinDecisionOutcome {
        switch self {
        case .approved(let v): .approved(try v.toDomain())
        case .rejected(let v): .rejected(try v.toDomain())
        case .alreadyDecided(let v): .alreadyDecided(try v.toDomain())
        case .conflict: .conflict
        case .memberLimitReached: .memberLimitReached
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: .unavailable
        }
    }
}

extension V2ActorInvitePersistedTimesWire {
    package init(domain: V2GroupInviteCreationTimestamps) {
        self.init(createdAtMicroseconds: domain.createdAt.microseconds,
                  expiresAtMicroseconds: domain.expiresAt.microseconds)
    }
    package func toDomain(createdAt: Date, expiresAt: Date) throws -> V2GroupInviteCreationTimestamps {
        guard v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds),
              v2PostgresTimestampMicrosecondsCanEncode(expiresAtMicroseconds),
              createdAtMicroseconds < expiresAtMicroseconds else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        // V2PersistenceTimestamp 自动生成的 Codable 携带精确整数；
        // 其 Date 初始化器必然舍入，不能用于重建不可变的数据库回执。
        func timestamp(_ value: Int64) throws -> V2PersistenceTimestamp {
            try JSONDecoder().decode(V2PersistenceTimestamp.self,
                                     from: Data("{\"microseconds\":\(value)}".utf8))
        }
        let pair = V2GroupInviteCreationTimestamps(createdAt: try timestamp(createdAtMicroseconds),
                                                   expiresAt: try timestamp(expiresAtMicroseconds))
        // 微秒数对是权威值。Date 与其差距应在 2 微秒内；
        // 若 Double 的单步精度更粗，则允许相差一个步长
        // （即 PostgreSQL 仍可精确存储、但远离 1970 年的日期）。
        func agrees(_ value: V2PersistenceTimestamp, _ date: Date) -> Bool {
            let difference = abs(value.date.timeIntervalSince(date))
            return difference < 0.000002 || difference <= date.timeIntervalSince1970.ulp
        }
        guard agrees(pair.createdAt, createdAt), agrees(pair.expiresAt, expiresAt) else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return pair
    }
}
extension V2ActorInviteCreatePersistenceWire {
    public init(domain: V2GroupInviteCreatePersistenceRequest) {
        self.init(inviteID: domain.inviteID, roomID: domain.roomID, actorUserID: domain.actorUserID,
                  operationID: domain.operationID, tokenDigest: .init(bytes: domain.tokenDigest),
                  requestedLifetimeSeconds: domain.requestedLifetimeSeconds, expiresAt: domain.expiresAt,
                  maximumApprovedUses: domain.maximumApprovedUses,
                  maximumActiveInvitesPerRoom: domain.maximumActiveInvitesPerRoom,
                  createdAt: domain.createdAt, evaluatedAt: domain.evaluatedAt,
                  persistedTimes: domain.persistedTimestamps.map(V2ActorInvitePersistedTimesWire.init(domain:)))
    }
    public func toDomain() throws -> V2GroupInviteCreatePersistenceRequest {
        guard requestedLifetimeSeconds > 0, maximumApprovedUses > 0,
              maximumActiveInvitesPerRoom > 0, expiresAt > createdAt,
              createdAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              evaluatedAt.timeIntervalSince1970.isFinite, persistedTimes != nil else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        let timestamps = try persistedTimes!.toDomain(createdAt: createdAt, expiresAt: expiresAt)
        return V2GroupInviteCreatePersistenceRequest(inviteID: inviteID, roomID: roomID, actorUserID: actorUserID,
                     operationID: operationID, tokenDigest: try tokenDigest.validatedBytes(),
                     requestedLifetimeSeconds: requestedLifetimeSeconds, expiresAt: expiresAt,
                     maximumApprovedUses: maximumApprovedUses,
                     maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom,
                     createdAt: createdAt, evaluatedAt: evaluatedAt).preservingTimestamps(timestamps)
    }
}
extension V2ActorInviteCreationIntentWire {
    public init(domain: V2GroupInviteCreationIntent) {
        self.init(request: .init(domain: domain.request), isReady: domain.isReady)
    }
    public func toDomain() throws -> V2GroupInviteCreationIntent {
        .init(request: try request.toDomain(), isReady: isReady)
    }
}
extension V2ActorInviteLocationWire {
    public init(domain: V2GroupInviteLocation) { self.init(inviteID: domain.inviteID, roomID: domain.roomID) }
    public func toDomain() -> V2GroupInviteLocation { .init(inviteID: inviteID, roomID: roomID) }
}
extension V2ActorStoredGroupInviteWire {
    public init(domain: V2StoredGroupInvite) {
        self.init(inviteID: domain.inviteID, roomID: domain.roomID, roomTitle: domain.roomTitle,
                  createdByUserID: domain.createdByUserID, creationOperationID: domain.creationOperationID,
                  state: domain.state, expiresAt: domain.expiresAt, maximumApprovedUses: domain.maximumApprovedUses,
                  approvedUseCount: domain.approvedUseCount, createdAt: domain.createdAt,
                  persistedTimes: domain.persistedTimestamps.map(V2ActorInvitePersistedTimesWire.init(domain:)))
    }
    public func toDomain() throws -> V2StoredGroupInvite {
        guard !roomTitle.isEmpty, roomTitle.utf8.count <= 120,
              maximumApprovedUses > 0, (0...maximumApprovedUses).contains(approvedUseCount),
              expiresAt > createdAt, expiresAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite else {
            throw V2GroupInvitationValidationError.invalidLink
        }
        var stored = V2StoredGroupInvite(inviteID: inviteID, roomID: roomID, roomTitle: roomTitle,
                     createdByUserID: createdByUserID, creationOperationID: creationOperationID,
                     state: state, expiresAt: expiresAt, maximumApprovedUses: maximumApprovedUses,
                     approvedUseCount: approvedUseCount, createdAt: createdAt)
        if let persistedTimes { stored.persistedTimestamps = try persistedTimes.toDomain(createdAt: createdAt, expiresAt: expiresAt) }
        return stored
    }
}
extension V2ActorJoinSubmissionPersistenceWire {
    public init(domain: V2GroupJoinSubmissionPersistenceRequest) {
        self.init(requestID: domain.requestID, applicantUserID: domain.applicantUserID,
                  operationID: domain.operationID, tokenDigest: .init(bytes: domain.tokenDigest),
                  note: domain.note, createdAt: domain.createdAt,
                  maximumPendingRequestsPerApplicant: domain.maximumPendingRequestsPerApplicant,
                  maximumPendingRequestsPerInvite: domain.maximumPendingRequestsPerInvite)
    }
    public func toDomain() throws -> V2GroupJoinSubmissionPersistenceRequest {
        guard note?.utf8.count ?? 0 <= 500, maximumPendingRequestsPerApplicant > 0,
              maximumPendingRequestsPerInvite > 0, createdAt.timeIntervalSince1970.isFinite else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(requestID: requestID, applicantUserID: applicantUserID,
                     operationID: operationID, tokenDigest: try tokenDigest.validatedBytes(),
                     note: note, createdAt: createdAt,
                     maximumPendingRequestsPerApplicant: maximumPendingRequestsPerApplicant,
                     maximumPendingRequestsPerInvite: maximumPendingRequestsPerInvite)
    }
}
extension V2ActorGroupJoinRequestRecordWire {
    public init(record: V2GroupJoinRequestRecord) {
        self.init(requestID: record.requestID, inviteID: record.inviteID, roomID: record.roomID,
                  applicant: .init(domain: record.applicant), note: record.note, state: record.state,
                  decisionOperationID: record.decisionOperationID, decidedByUserID: record.decidedByUserID,
                  createdAt: record.createdAt, decidedAt: record.decidedAt)
    }
    public func toRecord() throws -> V2GroupJoinRequestRecord {
        guard note?.utf8.count ?? 0 <= 500,
              createdAt.timeIntervalSince1970.isFinite,
              decidedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw V2GroupInvitationValidationError.invalidRequest
        }
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNote == note, normalizedNote?.isEmpty != true,
              state != .pending || (decisionOperationID == nil && decidedByUserID == nil && decidedAt == nil),
              state == .approved || state == .rejected || state == .cancelled || decidedAt == nil else {
            throw V2GroupInvitationValidationError.invalidRequest
        }
        return .init(requestID: requestID, inviteID: inviteID, roomID: roomID,
                     applicant: try applicant.toDomain(), note: note, state: state,
                     decisionOperationID: decisionOperationID, decidedByUserID: decidedByUserID,
                     createdAt: createdAt, decidedAt: decidedAt)
    }
}
extension V2ActorGroupJoinRequestRecordPageWire {
    public init(domain: V2GroupJoinRequestRecordPage) {
        self.init(requests: domain.requests.map(V2ActorGroupJoinRequestRecordWire.init(record:)), nextCursor: domain.nextCursor)
    }
    public func toDomain() throws -> V2GroupJoinRequestRecordPage {
        guard requests.count <= 100, nextCursor?.utf8.count ?? 0 <= 4096 else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(requests: try requests.map { try $0.toRecord() }, nextCursor: nextCursor)
    }
}
extension V2ActorGroupJoinApprovalPersistenceOutcomeWire {
    public init(domain: V2GroupJoinApprovalPersistenceOutcome) {
        switch domain {
        case .approved(let v): self = .approved(.init(record: v))
        case .alreadyDecided(let v): self = .alreadyDecided(.init(record: v))
        case .conflict: self = .conflict
        case .memberLimitReached: self = .memberLimitReached
        case .rateLimited(let n): self = .rateLimited(retryAfterSeconds: n)
        case .unavailable: self = .unavailable
        }
    }
    public func toDomain() throws -> V2GroupJoinApprovalPersistenceOutcome {
        switch self {
        case .approved(let v): .approved(try v.toRecord())
        case .alreadyDecided(let v): .alreadyDecided(try v.toRecord())
        case .conflict: .conflict
        case .memberLimitReached: .memberLimitReached
        case .rateLimited(let n): .rateLimited(retryAfterSeconds: n)
        case .unavailable: .unavailable
        }
    }
}
extension V2ActorGroupJoinDecisionPreparationOutcomeWire {
    public init(domain: V2GroupJoinDecisionPreparationOutcome) {
        switch domain {
        case .rejected(let v): self = .rejected(.init(record: v))
        case .alreadyApproved(let v): self = .alreadyApproved(.init(record: v))
        case .alreadyRejected(let v): self = .alreadyRejected(.init(record: v))
        case .decisionConflict: self = .decisionConflict
        case .inviteExhausted: self = .inviteExhausted
        }
    }
    public func toDomain() throws -> V2GroupJoinDecisionPreparationOutcome {
        switch self {
        case .rejected(let v): .rejected(try v.toRecord())
        case .alreadyApproved(let v): .alreadyApproved(try v.toRecord())
        case .alreadyRejected(let v): .alreadyRejected(try v.toRecord())
        case .decisionConflict: .decisionConflict
        case .inviteExhausted: .inviteExhausted
        }
    }
}

extension V2ActorGroupJoinQuotaIntentWire {
    package init(domain: V2GroupJoinQuotaIntent) {
        self.init(applicantUserID: .init(uuid: domain.applicantUserID),
                  operationID: .init(uuid: domain.operationID), requestID: .init(uuid: domain.requestID),
                  roomID: .init(uuid: domain.roomID), inviteID: .init(uuid: domain.inviteID),
                  tokenDigest: .init(bytes: domain.tokenDigest), note: domain.note,
                  maximumPendingPerInvite: domain.maximumPendingPerInvite, generation: domain.generation,
                  phase: V2ActorGroupJoinQuotaPhaseWire(rawValue: domain.phase.rawValue)!,
                  outcome: domain.outcome.flatMap { V2ActorGroupJoinQuotaOutcomeWire(rawValue: $0.rawValue) },
                  targetRequestID: domain.targetRequestID.map(GroupJoinRequestID.init(uuid:)),
                  createdAt: domain.createdAt, attemptCreatedAt: domain.attemptCreatedAt,
                  updatedAt: domain.updatedAt, nextCheckAt: domain.nextCheckAt,
                  leaseToken: domain.leaseToken, leaseUntil: domain.leaseUntil, attemptCount: domain.attemptCount)
    }
    package func toDomain() throws -> V2GroupJoinQuotaIntent {
        guard let applicant = applicantUserID.uuidValue, let operation = operationID.uuidValue,
              let request = requestID.uuidValue, let room = roomID.uuidValue, let invite = inviteID.uuidValue,
              maximumPendingPerInvite > 0, generation > 0, attemptCount >= 0,
              Self.isPersistable(phase: phase, outcome: outcome, hasTarget: targetRequestID != nil,
                                 hasLease: leaseToken != nil || leaseUntil != nil),
              note?.utf8.count ?? 0 <= 500,
              v2PostgresTimestampCanEncode(createdAt), v2PostgresTimestampCanEncode(attemptCreatedAt),
              v2PostgresTimestampCanEncode(updatedAt), v2PostgresTimestampCanEncode(nextCheckAt),
              leaseUntil.map(v2PostgresTimestampCanEncode) ?? true,
              let phase = V2GroupJoinQuotaPhase(rawValue: phase.rawValue),
              outcome == nil || V2GroupJoinQuotaOutcome(rawValue: outcome!.rawValue) != nil,
              targetRequestID == nil || targetRequestID?.uuidValue != nil else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(applicantUserID: applicant, operationID: operation, requestID: request,
                     roomID: room, inviteID: invite, tokenDigest: try tokenDigest.validatedBytes(),
                     note: note, maximumPendingPerInvite: maximumPendingPerInvite, generation: generation,
                     phase: phase, outcome: outcome.flatMap { V2GroupJoinQuotaOutcome(rawValue: $0.rawValue) },
                     targetRequestID: targetRequestID?.uuidValue, createdAt: createdAt,
                     attemptCreatedAt: attemptCreatedAt, updatedAt: updatedAt, nextCheckAt: nextCheckAt,
                     leaseToken: leaseToken, leaseUntil: leaseUntil, attemptCount: attemptCount)
    }
}
extension V2ActorGroupJoinQuotaIntentWire {
    /// 与 group_join_quota_outcome_check 和 group_join_quota_lease_check 对应。
    /// 预留会重放已重试的操作，即使其请求已经以终态意图结束；
    /// 因此每个可持久化阶段都必须在线路协议中表示。
    package static func isPersistable(phase: V2ActorGroupJoinQuotaPhaseWire, outcome: V2ActorGroupJoinQuotaOutcomeWire?,
                              hasTarget: Bool, hasLease: Bool) -> Bool {
        guard !hasLease || phase == .held || phase == .tracking else { return false }
        switch (phase, outcome) {
        case (.held, nil): return !hasTarget
        case (.tracking, .pending?): return hasTarget
        case (.denied, .unavailable?), (.denied, .rateLimited?), (.denied, .permissionDenied?): return !hasTarget
        case (.terminal, .approved?), (.terminal, .rejected?), (.terminal, .cancelled?): return hasTarget
        case (.terminal, .alreadyMember?): return !hasTarget
        default: return false
        }
    }
}

extension V2ActorGroupJoinOwnerSubmissionWire {
    package init(domain: V2GroupJoinOwnerSubmission) {
        self.init(outcome: V2ActorGroupJoinQuotaOutcomeWire(rawValue: domain.outcome.rawValue)!,
                  targetRequestID: domain.targetRequestID.map(GroupJoinRequestID.init(uuid:)),
                  wasInserted: domain.wasInserted)
    }
    package func toDomain() throws -> V2GroupJoinOwnerSubmission {
        guard let outcome = V2GroupJoinQuotaOutcome(rawValue: outcome.rawValue),
              targetRequestID == nil || targetRequestID?.uuidValue != nil else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        return .init(outcome: outcome, targetRequestID: targetRequestID?.uuidValue,
                     wasInserted: wasInserted)
    }
}

extension V2ActorResolvedInvitePreviewQueryWire {
    public func validatedDigest() throws -> Data { try tokenDigest.validatedBytes() }
}

extension V2ActorGroupInvitePreviewPersistenceOutcomeWire {
    public init(domain: V2GroupInvitePreviewPersistenceOutcome) {
        switch domain {
        case .available(let value): self = .available(.init(record: value))
        case .unavailable: self = .unavailable
        }
    }
    public func toDomain() throws -> V2GroupInvitePreviewPersistenceOutcome {
        switch self {
        case .available(let value): .available(try value.toRecord())
        case .unavailable: .unavailable
        }
    }
}
