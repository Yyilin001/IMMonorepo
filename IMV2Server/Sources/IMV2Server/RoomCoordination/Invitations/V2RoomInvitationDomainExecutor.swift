import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 在已授权的一个执行轮次内，仅处理邀请工作流中归属房间的部分。
/// 密钥签发、摘要查找和全局额度仍由控制域负责。
public struct V2RoomInvitationDomainExecutor: Sendable {
    private let database: any Database
    private let token: V2RoomActivationToken
    private let identities: any V2GroupInvitationIdentityReading
    private let capacityProfile: V2CapacityProfile
    private let makeEventID: @Sendable () throws -> EventID
    private let now: @Sendable () -> Date

    public init(database: any Database, token: V2RoomActivationToken,
                identities: any V2GroupInvitationIdentityReading,
                capacityProfile: V2CapacityProfile,
                makeEventID: @escaping @Sendable () throws -> EventID = { try EventID(UUID().uuidString) },
                now: @escaping @Sendable () -> Date = Date.init) throws {
        _ = try V2RoomActivationWriteScope(tokens: [token])
        self.database = database
        self.token = token
        self.identities = identities
        self.capacityProfile = capacityProfile
        self.makeEventID = makeEventID
        self.now = now
    }

    private func store(roomID: RoomID, inviteID: GroupInviteID? = nil) throws -> PostgresV2GroupInvitationStore {
        guard roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        return try .init(database: database, identities: identities,
                         activationToken: token, inviteID: inviteID)
    }

    public func execute(_ query: V2RoomInvitationQuery) async throws -> V2RoomInvitationResult {
        let owner = try store(roomID: query.roomID,
                              inviteID: query.inviteIDForOwnerBinding)
        switch query {
        case .active(let request):
            let values = try await owner.activeInvites(roomID: request.roomID,
                                                        actorUserID: request.actorUserID, now: now())
            return .activeStored(values.map(V2ActorStoredGroupInviteWire.init(domain:)))
        case .pending(let request):
            let page = try await owner.pendingRequests(roomID: request.roomID,
                reviewerUserID: request.reviewerUserID, cursor: request.cursor,
                pageSize: request.validatedPageSize(), now: now())
            return .pendingRecords(.init(domain: page))
        case .resolvedPreview(let request):
            let outcome = try await owner.preview(tokenDigest: request.validatedDigest(),
                applicantUserID: request.applicantUserID, now: now())
            return .resolvedPreview(.init(domain: outcome))
        case .preflightCreation(let request):
            let existing = try await owner.preflightCreation(request.toDomain())
            return .preflightStored(existing.map(V2ActorStoredGroupInviteWire.init(domain:)))
        case .reservedObservation(let request):
            return .reservedObservation(try await owner.observeReservedSubmission(request.toDomain()).map(V2ActorGroupJoinOwnerSubmissionWire.init(domain:)))
        case .reservedSubmissionResponse(let request):
            let response = try await owner.reservedSubmissionResponse(
                request.intent.toDomain(), observed: request.observed.toDomain())
            return .submission(.init(domain: response))
        }
    }
}

private extension V2RoomInvitationQuery {
    var inviteIDForOwnerBinding: GroupInviteID? {
        switch self {
        case .resolvedPreview(let value): value.inviteID
        case .reservedObservation(let value): value.inviteID
        case .reservedSubmissionResponse(let value): value.intent.inviteID
        case .preflightCreation(let value): value.inviteID
        case .active, .pending: nil
        }
    }
}
