import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Executes only the room-owned half of invitation workflows under one granted turn.
/// Secret issuance, digest lookup and global quota remain control-domain work.
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

    public func execute(_ command: V2RoomInvitationCommand) async throws -> V2RoomInvitationResult {
        let owner = try store(roomID: command.roomID,
                              inviteID: command.inviteIDForOwnerBinding)
        switch command {
        case .create:
            // User creation first needs a durable control intent and a fixed digest.
            throw V2GroupInvitationServiceError.invalidRequest
        case .commitCreation(let request):
            let created = try await owner.create(request.toDomain())
            return .createdStored(.init(domain: created))
        case .revoke(let request):
            try await owner.revoke(inviteID: request.inviteID, roomID: request.roomID,
                                   actorUserID: request.actorUserID, operationID: request.operationID,
                                   now: now())
            return .revoked
        case .decide(let request):
            switch request.decision {
            case .approve:
                let outcome = try await owner.approve(roomID: request.roomID,
                    requestID: request.requestID, reviewerUserID: request.reviewerUserID,
                    operationID: request.operationID, capacityProfile: capacityProfile,
                    eventID: makeEventID(), now: now())
                return .approval(.init(domain: outcome))
            case .reject:
                let outcome = try await owner.reject(roomID: request.roomID,
                    requestID: request.requestID, reviewerUserID: request.reviewerUserID,
                    operationID: request.operationID, now: now())
                return .rejection(.init(domain: outcome))
            }
        case .cancel(let request):
            let record = try await owner.cancel(roomID: request.roomID,
                requestID: request.requestID, applicantUserID: request.applicantUserID, now: now())
            return .cancelledRecord(.init(record: record))
        case .submitReserved(let request):
            let result = try await owner.applyReservedSubmission(request.toDomain(), now: now())
            return .reservedSubmission(.init(domain: result))
        }
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
        case .reservedSubmissionResponse(let request):
            let response = try await owner.reservedSubmissionResponse(
                request.intent.toDomain(), observed: request.observed.toDomain())
            return .submission(.init(domain: response))
        }
    }
}

private extension V2RoomInvitationCommand {
    var inviteIDForOwnerBinding: GroupInviteID? {
        switch self {
        case .commitCreation(let value): value.inviteID
        case .revoke(let value): value.inviteID
        case .submitReserved(let value): value.inviteID
        case .create, .decide, .cancel: nil
        }
    }
}

private extension V2RoomInvitationQuery {
    var inviteIDForOwnerBinding: GroupInviteID? {
        switch self {
        case .resolvedPreview(let value): value.inviteID
        case .reservedSubmissionResponse(let value): value.intent.inviteID
        case .preflightCreation(let value): value.inviteID
        case .active, .pending: nil
        }
    }
}
