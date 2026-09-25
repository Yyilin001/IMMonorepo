import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 组合入口提供 RoomRef 调用；此控制协调器绝不解析所有者数据库。
public struct V2ActorInvitationRoomPort: Sendable {
    public let command: @Sendable (V2RoomInvitationCommand, ContinuousClock.Instant) async throws -> V2RoomInvitationResult
    public let query: @Sendable (V2RoomInvitationQuery, ContinuousClock.Instant) async throws -> V2RoomInvitationResult

    public init(command: @escaping @Sendable (V2RoomInvitationCommand, ContinuousClock.Instant) async throws -> V2RoomInvitationResult,
                query: @escaping @Sendable (V2RoomInvitationQuery, ContinuousClock.Instant) async throws -> V2RoomInvitationResult) {
        self.command = command
        self.query = query
    }
}

/// 前台与恢复共用的控制侧密钥、目录和配额工作流。
public struct V2ActorInvitationCoordinator: Sendable {
    private let room: V2ActorInvitationRoomPort
    private let directory: any V2GroupInviteDirectory
    private let identities: any V2GroupInvitationIdentityReading
    private let quota: PostgresV2GroupJoinQuotaStore
    private let secretIssuer: V2GroupInviteSecretIssuer
    private let policy: V2GroupInvitationPolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(controlDatabase: any Database, room: V2ActorInvitationRoomPort,
                secretIssuer: V2GroupInviteSecretIssuer,
                policy: V2GroupInvitationPolicy = .standard,
                makeUUID: @escaping @Sendable () -> UUID = UUID.init,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.room = room
        self.directory = PostgresV2GroupInviteDirectory(database: controlDatabase)
        self.identities = PostgresV2GroupInvitationIdentityReader(database: controlDatabase)
        self.quota = .init(database: controlDatabase)
        self.secretIssuer = secretIssuer
        self.policy = policy
        self.makeUUID = makeUUID
        self.now = now
    }

    public func create(_ input: V2ActorCreateGroupInviteWire,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        let request = try input.toDomain()
        guard request.lifetime >= policy.minimumLifetime,
              request.lifetime <= policy.maximumLifetime,
              let seconds = Int(exactly: request.lifetime.rounded(.towardZero)),
              request.maximumApprovedUses <= policy.maximumApprovedUses else {
            throw V2GroupInvitationServiceError.invalidRequest
        }
        let issuedAt = now()
        let secret = try secretIssuer.secret(actorUserID: request.actorUserID, operationID: request.operationID)
        var candidate = V2GroupInviteCreatePersistenceRequest(
            inviteID: .init(uuid: makeUUID()), roomID: request.roomID,
            actorUserID: request.actorUserID, operationID: request.operationID,
            tokenDigest: secretIssuer.digest(secret), requestedLifetimeSeconds: seconds,
            expiresAt: issuedAt.addingTimeInterval(request.lifetime),
            maximumApprovedUses: request.maximumApprovedUses,
            maximumActiveInvitesPerRoom: policy.maximumActiveInvitesPerRoom,
            createdAt: issuedAt)
        // 分配任何全局意图前先读取选定的房间轮次。
        // 重试时既有所有者历史固定 ID 和精确 PostgreSQL 微秒值。
        guard case .preflightStored(let previous) = try await room.query(
            .preflightCreation(.init(domain: candidate)), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        if let previous {
            let saved = try previous.toDomain()
            candidate = .init(inviteID: saved.inviteID, roomID: candidate.roomID,
                actorUserID: candidate.actorUserID, operationID: candidate.operationID,
                tokenDigest: candidate.tokenDigest,
                requestedLifetimeSeconds: candidate.requestedLifetimeSeconds,
                expiresAt: saved.expiresAt,
                maximumApprovedUses: candidate.maximumApprovedUses,
                maximumActiveInvitesPerRoom: candidate.maximumActiveInvitesPerRoom,
                createdAt: saved.createdAt, evaluatedAt: candidate.evaluatedAt)
                .preservingTimestamps(saved.persistedTimestamps)
        }
        let stored = try await V2GroupInviteCreationCoordinator(directory: directory).create(candidate) { fixed in
            guard case .createdStored(let value) = try await room.command(
                .commitCreation(.init(domain: fixed)), deadline) else {
                throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
            return try value.toDomain()
        }
        let link = try V2GroupInviteLink(inviteID: stored.inviteID, roomID: stored.roomID,
            roomTitle: stored.roomTitle, secret: secret, state: stored.state,
            expiresAt: stored.expiresAt, maximumApprovedUses: stored.maximumApprovedUses,
            approvedUseCount: stored.approvedUseCount, createdAt: stored.createdAt)
        return .created(.init(domain: link))
    }

    public func resumeCreation(_ intent: V2GroupInviteCreationIntent, evaluatedAt: Date,
                               deadline: ContinuousClock.Instant) async throws {
        // 重放同一持久化的准备、所有者处理与收尾工作流，
        // 不签发密钥，也不生成新的房间侧身份。
        _ = try await V2GroupInviteCreationCoordinator(directory: directory).create(
            intent.request.evaluated(at: evaluatedAt)) { fixed in
            guard case .createdStored(let value) = try await room.command(
                .commitCreation(.init(domain: fixed)), deadline) else {
                throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
            return try value.toDomain()
        }
    }

    public func active(_ input: V2ActorActiveGroupInvitesQueryWire,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        guard case .activeStored(let stored) = try await room.query(.active(input), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        let ready = try await directory.readyInvites(roomID: input.roomID,
            inviteIDs: Set(stored.map(\.inviteID)))
        let links = try stored.filter { ready.contains($0.inviteID) }.map { value in
            let secret = try secretIssuer.secret(actorUserID: value.createdByUserID,
                                                 operationID: value.creationOperationID)
            let domain = try value.toDomain()
            return V2ActorGroupInviteLinkWire(domain: try .init(inviteID: domain.inviteID,
                roomID: domain.roomID, roomTitle: domain.roomTitle, secret: secret,
                state: domain.state, expiresAt: domain.expiresAt,
                maximumApprovedUses: domain.maximumApprovedUses,
                approvedUseCount: domain.approvedUseCount, createdAt: domain.createdAt))
        }
        return .active(links)
    }

    public func previewBySecret(_ input: V2ActorInvitePreviewBySecretWire,
                                deadline: ContinuousClock.Instant) async throws -> V2ActorInvitationCoordinatorResult {
        let digest = secretIssuer.digest(try input.secret.toDomain())
        guard let location = try await directory.resolve(tokenDigest: digest) else { return .preview(nil) }
        guard case .resolvedPreview(let outcome) = try await room.query(.resolvedPreview(.init(
            roomID: location.roomID, inviteID: location.inviteID,
            applicantUserID: input.applicantUserID,
            tokenDigest: .init(bytes: digest))), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        switch outcome {
        case .available(let value): return .preview(value)
        case .unavailable: return .preview(nil)
        }
    }

    public func submitBySecret(_ input: V2ActorSubmitGroupJoinWire,
                               deadline: ContinuousClock.Instant) async throws -> V2ActorInvitationCoordinatorResult {
        let request = try input.toDomain()
        let digest = secretIssuer.digest(request.secret)
        guard let location = try await directory.resolve(tokenDigest: digest) else {
            return .submission(.unavailable)
        }
        guard try await identities.read(userIDs: [request.applicantUserID])[request.applicantUserID]?.isActive == true else {
            throw V2GroupInvitationServiceError.permissionDenied
        }
        let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = now()
        let seeded = V2GroupJoinSubmissionPersistenceRequest(requestID: .init(uuid: makeUUID()),
            applicantUserID: request.applicantUserID, operationID: request.operationID,
            tokenDigest: digest, note: note?.isEmpty == false ? note : nil,
            createdAt: createdAt,
            maximumPendingRequestsPerApplicant: policy.maximumPendingRequestsPerApplicant,
            maximumPendingRequestsPerInvite: policy.maximumPendingRequestsPerInvite)
        guard case .reserved(let intent) = try await quota.reserve(seeded,
            roomID: location.roomID, inviteID: location.inviteID, now: createdAt) else {
            return .submission(.rateLimited)
        }
        let observed = try await applyReserved(intent, deadline: deadline)
        guard case .submission(let value) = try await room.query(.reservedSubmissionResponse(.init(
            intent: .init(domain: intent), observed: .init(domain: observed))), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return .submission(value)
    }

    /// 恢复使用已存代次，绝不预留第二个槽位。
    func resumeSubmission(_ intent: V2GroupJoinQuotaIntent,
                          deadline: ContinuousClock.Instant) async throws {
        _ = try await applyReserved(intent, deadline: deadline)
    }

    private func applyReserved(_ intent: V2GroupJoinQuotaIntent,
                               deadline: ContinuousClock.Instant) async throws -> V2GroupJoinOwnerSubmission {
        guard case .reservedSubmission(let value) = try await room.command(
            .submitReserved(.init(domain: intent)), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        let observed = try value.toDomain()
        try await quota.resolve(intent, outcome: observed.outcome,
                                targetRequestID: observed.targetRequestID, now: now())
        return observed
    }

    public func pending(_ input: V2ActorPendingGroupJoinsQueryWire,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        guard case .pendingRecords(let page) = try await room.query(.pending(input), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return .pending(.init(requests: page.requests.map(\.publicView), nextCursor: page.nextCursor))
    }

    public func revoke(_ input: V2ActorRevokeGroupInviteWire,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        guard case .revoked = try await room.command(.revoke(input), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return .revoked
    }

    public func decide(_ input: V2ActorDecideGroupJoinWire,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        let value = try await room.command(.decide(input), deadline)
        let outcome: V2ActorGroupJoinDecisionOutcomeWire
        switch value {
        case .approval(let result):
            switch result {
            case .approved(let record):
                try await quota.releaseTerminal(record.toRecord(), now: now())
                outcome = .approved(record.publicView)
            case .alreadyDecided(let record):
                try await quota.releaseTerminal(record.toRecord(), now: now())
                outcome = .alreadyDecided(record.publicView)
            case .conflict: outcome = .conflict
            case .memberLimitReached: outcome = .memberLimitReached
            case .rateLimited(let seconds): outcome = .rateLimited(retryAfterSeconds: seconds)
            case .unavailable: outcome = .unavailable
            }
        case .rejection(let result):
            switch result {
            case .rejected(let record):
                try await quota.releaseTerminal(record.toRecord(), now: now())
                outcome = .rejected(record.publicView)
            case .alreadyApproved(let record), .alreadyRejected(let record):
                try await quota.releaseTerminal(record.toRecord(), now: now())
                outcome = .alreadyDecided(record.publicView)
            case .decisionConflict: outcome = .conflict
            case .inviteExhausted: outcome = .memberLimitReached
            }
        default: throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return .decided(outcome)
    }

    public func cancel(_ input: V2ActorCancelGroupJoinWire,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        guard case .cancelledRecord(let record) = try await room.command(.cancel(input), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        try await quota.releaseTerminal(record.toRecord(), now: now())
        return .cancelled(record.publicView)
    }
}

private extension V2ActorGroupJoinRequestRecordWire {
    var publicView: V2ActorGroupJoinRequestWire {
        .init(requestID: requestID, inviteID: inviteID, roomID: roomID,
              applicant: applicant, note: note, state: state,
              resumableDecisionOperationID: nil, createdAt: createdAt, decidedAt: decidedAt)
    }
}

struct V2ActorInvitationCreationResumer: V2GroupInviteCreationResuming {
    let coordinator: V2ActorInvitationCoordinator
    let deadline: @Sendable () -> ContinuousClock.Instant

    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        try await coordinator.resumeCreation(intent, evaluatedAt: now, deadline: deadline())
    }
}
