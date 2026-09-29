import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 组合入口提供 RoomRef 调用；此控制协调器绝不解析所有者数据库。
public struct V2ActorInvitationRoomPort: Sendable {
    public let query: @Sendable (V2RoomInvitationQuery,ContinuousClock.Instant) async throws -> V2RoomInvitationResult
    public init(query:@escaping @Sendable (V2RoomInvitationQuery,ContinuousClock.Instant) async throws -> V2RoomInvitationResult) { self.query=query }
}

/// 前台与恢复共用的控制侧密钥、目录和配额工作流。
public struct V2ActorInvitationCoordinator: Sendable {
    let operations: V2GroupInvitationOperationRoomPort
    let commands: any V2GroupInvitationCommandJournal
    let room: V2ActorInvitationRoomPort
    let directory: any V2GroupInviteDirectory
    let quota: any V2GroupJoinQuotaAuthority
    let secretIssuer: V2GroupInviteSecretIssuer
    let policy: V2GroupInvitationPolicy
    let makeUUID: @Sendable () -> UUID
    let now: @Sendable () -> Date

    package init(commands: any V2GroupInvitationCommandJournal,
                 directory: any V2GroupInviteDirectory,
                 quota: any V2GroupJoinQuotaAuthority,
                 room: V2ActorInvitationRoomPort,
                 operations: V2GroupInvitationOperationRoomPort,
                 secretIssuer: V2GroupInviteSecretIssuer,
                 policy: V2GroupInvitationPolicy = .standard,
                 makeUUID: @escaping @Sendable () -> UUID = UUID.init,
                 now: @escaping @Sendable () -> Date = Date.init) {
        self.operations = operations
        self.commands = commands
        self.room = room
        self.directory = directory
        self.quota = quota
        self.secretIssuer = secretIssuer
        self.policy = policy
        self.makeUUID = makeUUID
        self.now = now
    }

    public func resumeCreation(_ intent: V2GroupInviteCreationIntent, evaluatedAt: Date,
                               deadline: ContinuousClock.Instant) async throws {
        guard let command = try await commands.load(actor:intent.request.actorUserID.uuidValue!,operation:intent.request.operationID.uuidValue!) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        _ = try await executeOperation(command,deadline:deadline)
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



    /// 恢复使用已存代次，绝不预留第二个槽位。
    package func resumeSubmission(_ intent: V2GroupJoinQuotaIntent,
                          deadline: ContinuousClock.Instant) async throws {
        guard let command = try await commands.load(actor:intent.applicantUserID,operation:intent.operationID) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let result = try await operations.submit(.init(command:command,quotaIntent:.init(domain:intent)),deadline)
        if case .deferred = result {
            try await quota.resolve(intent,outcome:.rateLimited,targetRequestID:nil,now:now())
        }
        try await reconcileQuota(intent,deadline:deadline)
    }



    public func pending(_ input: V2ActorPendingGroupJoinsQueryWire,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomInvitationResult {
        guard case .pendingRecords(let page) = try await room.query(.pending(input), deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return .pending(.init(requests: page.requests.map(\.publicView), nextCursor: page.nextCursor))
    }






}

private extension V2ActorGroupJoinRequestRecordWire {
    var publicView: V2ActorGroupJoinRequestWire {
        .init(requestID: requestID, inviteID: inviteID, roomID: roomID,
              applicant: applicant, note: note, state: state,
              resumableDecisionOperationID: nil, createdAt: createdAt, decidedAt: decidedAt)
    }
}
