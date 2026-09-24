import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 actor invitation wire")
struct V2ActorInvitationWireTests {
    private let actor = try! UserID("actor-a")
    private let roomID = try! RoomID("room-b")
    private let inviteID = try! GroupInviteID("invite-c")
    private let requestID = try! GroupJoinRequestID("request-d")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let secret = try! V2GroupInviteSecret(String(repeating: "a", count: 43))

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func completePublicValuesAndOutcomes() throws {
        let link = try V2GroupInviteLink(inviteID: inviteID, roomID: roomID, roomTitle: "Team", secret: secret,
                                         state: .active, expiresAt: now.addingTimeInterval(3600),
                                         maximumApprovedUses: 8, approvedUseCount: 3, createdAt: now)
        #expect(try roundTrip(V2ActorGroupInviteLinkWire(domain: link)).toDomain() == link)
        let handle = try V2PublicHandle("alice_1")
        let applicant = try V2PublicIdentity(userID: actor, handle: handle, displayName: "Alice", accountKind: .regular)
        let request = try V2GroupJoinRequest(requestID: requestID, inviteID: inviteID, roomID: roomID,
                                             applicant: applicant, note: "Hello", state: .approving,
                                             resumableDecisionOperationID: try GroupJoinDecisionOperationID("decision-e"),
                                             createdAt: now, decidedAt: nil)
        let wire = V2ActorGroupJoinRequestWire(domain: request)
        #expect(try roundTrip(wire).toDomain() == request)
        let result = V2ActorGroupJoinDecisionOutcomeWire(domain: .alreadyDecided(request))
        #expect(try roundTrip(result).toDomain() == .alreadyDecided(request))
        let previewRecord = V2GroupInvitePreviewRecord(inviteID: inviteID, roomID: roomID,
            roomTitle: "Team", expiresAt: now.addingTimeInterval(3600), requestState: .pending,
            requestID: requestID, isAlreadyMember: false)
        let preview = V2ActorGroupInvitePreviewPersistenceOutcomeWire(domain: .available(previewRecord))
        #expect(try roundTrip(preview).toDomain() == .available(previewRecord))
        #expect(try roundTrip(V2ActorGroupInvitePreviewPersistenceOutcomeWire.unavailable).toDomain() == .unavailable)
        let page = V2GroupJoinRequestPage(requests: [request], nextCursor: "next-page")
        #expect(try roundTrip(V2ActorGroupJoinRequestPageWire(domain: page)).toDomain() == page)
    }

    @Test func confidentialInputsAndReplay() throws {
        let operationID = try GroupInviteOperationID("invite-op")
        let create = V2ActorCreateGroupInviteWire(roomID: roomID, actorUserID: actor, operationID: operationID,
                                                   lifetime: 3600, maximumApprovedUses: 4)
        #expect(try roundTrip(create).toDomain().maximumApprovedUses == 4)
        let cancel = V2RoomInvitationCommand.cancel(.init(roomID: roomID, requestID: requestID, applicantUserID: actor))
        #expect(cancel.retryPolicy == .noAutomaticRetry)
        #expect(cancel.stableOperationIdentity == nil)
        #expect(V2RoomInvitationCommand.create(create).retryPolicy == .durableIdempotent)
        let secretWire = V2ActorInviteSecretWire(domain: secret)
        #expect(secretWire.description == "<redacted-group-invite-secret>")
        #expect(try roundTrip(secretWire).toDomain() == secret)
        let digest = V2ActorInviteTokenDigestWire(bytes: Data(repeating: 1, count: 32))
        #expect(try roundTrip(digest).validatedBytes() == digest.bytes)
        #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
            try V2ActorPendingGroupJoinsQueryWire(roomID: roomID, reviewerUserID: actor,
                                                  cursor: "bad-cursor", pageSize: 10).validatedPageSize()
        }

        #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
            try V2ActorInviteTokenDigestWire(bytes: Data()).validatedBytes()
        }
        #expect(throws: V2GroupInvitationValidationError.invalidSecret) {
            try V2ActorInviteSecretWire(rawValue: "short").toDomain()
        }
    }

    @Test func seededPersistenceAndInvalidWire() throws {
        let seed = V2GroupInviteCreatePersistenceRequest(inviteID: inviteID, roomID: roomID, actorUserID: actor,
            operationID: try GroupInviteOperationID("invite-op"), tokenDigest: Data(repeating: 2, count: 32),
            requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600),
            maximumApprovedUses: 8, maximumActiveInvitesPerRoom: 12, createdAt: now)
        let mirrored = try roundTrip(V2ActorInviteCreatePersistenceWire(domain: seed)).toDomain()
        #expect(mirrored.inviteID == seed.inviteID)
        #expect(mirrored.tokenDigest == seed.tokenDigest)
        #expect(mirrored.expiresAt == seed.expiresAt)
        #expect(mirrored.maximumActiveInvitesPerRoom == seed.maximumActiveInvitesPerRoom)
        #expect(throws: V2PublicIdentityValidationError.invalidHandle) {
            try V2ActorInvitationPublicIdentityWire(userID: actor, handle: "@Alice", displayName: "Alice", accountKind: .regular).toDomain()
        }
        #expect(throws: V2GroupInvitationValidationError.invalidPreview) {
            try V2ActorGroupInvitePreviewWire(inviteID: inviteID, roomID: roomID, roomTitle: "Team",
                expiresAt: now, requestState: .pending, requestID: nil, isAlreadyMember: false).toDomain()
        }
    }
    @Test func reservedQuotaIntentAndExactTimestamp() throws {
        let intent = V2GroupJoinQuotaIntent(
            applicantUserID: UUID(), operationID: UUID(), requestID: UUID(), roomID: UUID(), inviteID: UUID(),
            tokenDigest: Data(repeating: 7, count: 32), note: "Needs access", maximumPendingPerInvite: 10,
            generation: 2, phase: .held, outcome: nil, targetRequestID: nil,
            createdAt: now, attemptCreatedAt: now, updatedAt: now, nextCheckAt: now,
            leaseToken: UUID(), leaseUntil: now.addingTimeInterval(30), attemptCount: 1)
        let wire = V2ActorGroupJoinQuotaIntentWire(domain: intent)
        #expect(try roundTrip(wire).toDomain() == intent)
        #expect(V2RoomInvitationCommand.submitReserved(wire).retryPolicy == .durableIdempotent)
        let bad = V2ActorGroupJoinQuotaIntentWire(
            applicantUserID: wire.applicantUserID, operationID: wire.operationID, requestID: wire.requestID,
            roomID: wire.roomID, inviteID: wire.inviteID, tokenDigest: .init(bytes: Data()), note: wire.note,
            maximumPendingPerInvite: wire.maximumPendingPerInvite, generation: wire.generation,
            phase: wire.phase, outcome: wire.outcome, targetRequestID: wire.targetRequestID,
            createdAt: wire.createdAt, attemptCreatedAt: wire.attemptCreatedAt, updatedAt: wire.updatedAt,
            nextCheckAt: wire.nextCheckAt, leaseToken: wire.leaseToken, leaseUntil: wire.leaseUntil,
            attemptCount: wire.attemptCount)
        #expect(throws: V2GroupInvitationServiceError.invalidRequest) { try bad.toDomain() }
        // A retried operation whose request already ended is replayed with its
        // persisted terminal (or denied) intent; the wire must round-trip it.
        func settled(_ phase: V2GroupJoinQuotaPhase, _ outcome: V2GroupJoinQuotaOutcome?, target: UUID?) -> V2GroupJoinQuotaIntent {
            .init(applicantUserID: intent.applicantUserID, operationID: intent.operationID, requestID: intent.requestID,
                  roomID: intent.roomID, inviteID: intent.inviteID, tokenDigest: intent.tokenDigest, note: intent.note,
                  maximumPendingPerInvite: 10, generation: 2, phase: phase, outcome: outcome, targetRequestID: target,
                  createdAt: now, attemptCreatedAt: now, updatedAt: now, nextCheckAt: now,
                  leaseToken: nil, leaseUntil: nil, attemptCount: 1)
        }
        let target = UUID()
        for valid in [settled(.tracking, .pending, target: target), settled(.terminal, .cancelled, target: target),
                      settled(.terminal, .approved, target: target), settled(.terminal, .rejected, target: target),
                      settled(.terminal, .alreadyMember, target: nil), settled(.denied, .rateLimited, target: nil)] {
            #expect(try roundTrip(V2ActorGroupJoinQuotaIntentWire(domain: valid)).toDomain() == valid)
        }
        for invalid in [settled(.terminal, .pending, target: target), settled(.terminal, .cancelled, target: nil),
                        settled(.tracking, .pending, target: nil), settled(.denied, .approved, target: nil),
                        settled(.held, .cancelled, target: nil)] {
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                try V2ActorGroupJoinQuotaIntentWire(domain: invalid).toDomain()
            }
        }
        let seed = V2GroupInviteCreatePersistenceRequest(inviteID: inviteID, roomID: roomID, actorUserID: actor,
            operationID: try GroupInviteOperationID("invite-op"), tokenDigest: Data(repeating: 2, count: 32),
            requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600),
            maximumApprovedUses: 8, maximumActiveInvitesPerRoom: 12, createdAt: now)
        let seedWire = V2ActorInviteCreatePersistenceWire(domain: seed)
        #expect(try roundTrip(seedWire).toDomain().persistedTimestamps == seed.persistedTimestamps)
    }

}
