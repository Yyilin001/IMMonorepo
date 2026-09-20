import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 group invitation service")
struct V2GroupInvitationServiceTests {
    @Test("Invitation lifetime policy rejects nonrepresentable integer seconds")
    func policyLifetimeBounds() throws {
        for maximum in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), Double(Int.max).nextUp, 0, -1] {
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                _ = try V2GroupInvitationPolicy(maximumLifetime: maximum)
            }
        }
        for minimum in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1] {
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                _ = try V2GroupInvitationPolicy(minimumLifetime: minimum)
            }
        }
        let largest = Double(Int.max).nextDown
        #expect(try V2GroupInvitationPolicy(maximumLifetime: largest).maximumLifetime == largest)
        #expect(try V2GroupInvitationPolicy() == .standard)
    }

    @Test("Fractional lifetimes retain the existing truncation and absolute deadline")
    func fractionalLifetime() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let store = GroupInvitationStoreSpy()
        let service = V2GroupInvitationService(store: store, capacityProfile: invitationCapacityProfile(), secretIssuer: try .init(rawKey: Data(repeating: 0x19, count: 32)), now: { base })
        let link = try await service.create(.init(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()), lifetime: 3600.75, maximumApprovedUses: 1))
        let captured = try #require(await store.createdRequest())
        #expect(captured.requestedLifetimeSeconds == 3600)
        #expect(captured.expiresAt == base.addingTimeInterval(3600.75))
        #expect(link.expiresAt == captured.expiresAt)
    }

    @Test("issuer is retry stable, domain scoped, and stores only a digest")
    func issuesRetryStableSecret() throws {
        let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x2A, count: 32))
        let actor = try UserID("00000000-0000-0000-0000-000000000101")
        let operation = try GroupInviteOperationID("00000000-0000-0000-0000-000000000102")

        let first = try issuer.secret(actorUserID: actor, operationID: operation)
        let retry = try issuer.secret(actorUserID: actor, operationID: operation)
        let another = try issuer.secret(
            actorUserID: actor,
            operationID: .init("00000000-0000-0000-0000-000000000103")
        )

        #expect(first == retry)
        #expect(first != another)
        #expect(first.description == "<redacted-group-invite-secret>")
        #expect(issuer.digest(first).count == 32)
        #expect(issuer.digest(first) != Data(first.rawValue.utf8))
    }

    @Test("create validates policy before persistence and passes no plaintext token to the store")
    func createsThroughDigestBoundary() async throws {
        let store = GroupInvitationStoreSpy()
        let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x15, count: 32))
        let actor = try UserID("00000000-0000-0000-0000-000000000111")
        let operation = try GroupInviteOperationID("00000000-0000-0000-0000-000000000112")
        let room = try RoomID("00000000-0000-0000-0000-000000000113")
        let createdAt = Date(timeIntervalSince1970: 2_000_000_000)
        let generatedInvite = UUID(uuidString: "00000000-0000-0000-0000-000000000114")!
        let service = V2GroupInvitationService(
            store: store,
            capacityProfile: invitationCapacityProfile(),
            secretIssuer: issuer,
            makeUUID: { generatedInvite },
            now: { createdAt }
        )

        let link = try await service.create(.init(
            roomID: room,
            actorUserID: actor,
            operationID: operation,
            lifetime: 3_600,
            maximumApprovedUses: 12
        ))
        let captured = try #require(await store.createdRequest())

        #expect(captured.tokenDigest == issuer.digest(link.secret))
        #expect(captured.tokenDigest != Data(link.secret.rawValue.utf8))
        #expect(captured.requestedLifetimeSeconds == 3_600)
        #expect(captured.maximumApprovedUses == 12)
        #expect(captured.maximumActiveInvitesPerRoom == 20)
        #expect(link.inviteID.rawValue == generatedInvite.uuidString.lowercased())
        #expect(link.roomTitle == "受控邀请群")
    }

    @Test("create rejects out-of-policy lifetime before touching persistence")
    func rejectsInvalidLifetime() async throws {
        let store = GroupInvitationStoreSpy()
        let service = V2GroupInvitationService(
            store: store,
            capacityProfile: invitationCapacityProfile(),
            secretIssuer: try .init(rawKey: Data(repeating: 0x19, count: 32))
        )

        await #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
            _ = try await service.create(.init(
                roomID: try .init("00000000-0000-0000-0000-000000000121"),
                actorUserID: try .init("00000000-0000-0000-0000-000000000122"),
                operationID: try .init("00000000-0000-0000-0000-000000000123"),
                lifetime: 60,
                maximumApprovedUses: 1
            ))
        }
        #expect(await store.createdRequest() == nil)
    }
}

private actor GroupInvitationStoreSpy: V2GroupInvitationStore {
    private var capturedCreate: V2GroupInviteCreatePersistenceRequest?

    func create(_ request: V2GroupInviteCreatePersistenceRequest) throws -> V2StoredGroupInvite {
        capturedCreate = request
        return .init(
            inviteID: request.inviteID,
            roomID: request.roomID,
            roomTitle: "受控邀请群",
            createdByUserID: request.actorUserID,
            creationOperationID: request.operationID,
            state: .active,
            expiresAt: request.expiresAt,
            maximumApprovedUses: request.maximumApprovedUses,
            approvedUseCount: 0,
            createdAt: request.createdAt
        )
    }

    func createdRequest() -> V2GroupInviteCreatePersistenceRequest? { capturedCreate }

    func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) async throws -> [V2StoredGroupInvite] { throw UnusedStorePath() }
    func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) async throws { throw UnusedStorePath() }
    func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) async throws -> V2GroupInvitePreviewPersistenceOutcome { throw UnusedStorePath() }
    func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome { throw UnusedStorePath() }
    func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) async throws -> V2GroupJoinRequestRecordPage { throw UnusedStorePath() }
    func approve(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupJoinApprovalPersistenceOutcome { throw UnusedStorePath() }
    func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID, now: Date) async throws -> V2GroupJoinRequestRecord {
        throw V2GroupInvitationServiceError.requestNotFound
    }
    func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) async throws -> V2GroupJoinDecisionPreparationOutcome { throw UnusedStorePath() }
}

private struct UnusedStorePath: Error {}

private func invitationCapacityProfile() -> V2CapacityProfile {
    try! .init(
        id: "standard",
        limits: .init(
            maxEligibleMembers: 100, maxCommandsPerWindow: 100,

             retryAfterSeconds: 1
        )
    )
}
