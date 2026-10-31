import Foundation
import IMV2Core
import Testing
@testable import IMV2ActorContracts

@Suite("Closed room capability envelope")
struct V2RoomRequestTests {
    @Test("multi-viewer room reads have service identity and charge all target work")
    func profileCohortEnvelope() throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        let viewers = (0..<100).map { _ in V2ActorProfileVisibilityBatchWire(roomID: room,
            actorUserID: .init(uuid: UUID()), roomKind: .memberRoom, targetUserIDs: [target]) }
        func envelope(_ values: [V2ActorProfileVisibilityBatchWire], roomID: RoomID? = nil) -> V2RoomRequest {
            .mediaAuthorization(.profileVisibilityCohort(.init(roomID: roomID ?? room, requests: values)))
        }
        let valid = envelope(viewers)
        #expect(valid.actorUserID == nil && valid.roomID == room && valid.replayPolicy == .readOnly)
        #expect(valid.profileVisibilityTargetCount == 100 && !valid.hasStableOperationID && !valid.canShareSendTurn)
        let retainedBytes = V2ActorPayloadBudget.retainedBytes(of: valid)
        let encoded = try V2ActorProtobuf.encode(valid)
        #expect(retainedBytes <= 64 * 1_024 && retainedBytes >= encoded.count)
        #expect(try V2ActorProtobuf.decode(V2RoomRequest.self, from: encoded) == valid)
        #expect(try JSONDecoder().decode(V2RoomRequest.self, from: JSONEncoder().encode(valid)) == valid)
        #expect(envelope([]).profileVisibilityTargetCount == nil)
        #expect(envelope(viewers + [viewers[0]]).profileVisibilityTargetCount == nil)
        #expect(envelope(viewers, roomID: .init(uuid: UUID())).profileVisibilityTargetCount == nil)
        let twoTargets = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: viewers[0].actorUserID,
            roomKind: .group, targetUserIDs: [target, .init(uuid: UUID())])
        #expect(envelope(Array(repeating: twoTargets, count: 50)).profileVisibilityTargetCount == 100)
        #expect(envelope(Array(repeating: twoTargets, count: 51)).profileVisibilityTargetCount == nil)
        #expect(envelope([.init(roomID: room, actorUserID: try .init("invalid"), roomKind: .group,
            targetUserIDs: [target])]).profileVisibilityTargetCount == nil)
        // A larger or malformed model must still charge every retained item;
        // eligibility validation is not a way to make its memory cost disappear.
        #expect(V2ActorPayloadBudget.retainedBytes(of: envelope(viewers + viewers)) > retainedBytes)
    }

    @Test("profile cohort eligibility checks shape without changing the per-user principal")
    func profileCohortEligibility() throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        func request(_ targets: [UserID], actor: UserID) -> V2RoomRequest {
            .mediaAuthorization(.profileVisibilityBatch(.init(roomID: room, actorUserID: actor,
                roomKind: .group, targetUserIDs: targets)))
        }
        let valid = request([target], actor: actor)
        #expect(valid.profileVisibilityTargetCount == 1)
        #expect(valid.actorUserID == actor && valid.replayPolicy == .readOnly && !valid.canShareSendTurn)
        #expect(try JSONDecoder().decode(V2RoomRequest.self, from: JSONEncoder().encode(valid)) == valid)
        #expect(request([], actor: actor).profileVisibilityTargetCount == nil)
        #expect(request([target, target], actor: actor).profileVisibilityTargetCount == nil)
        #expect(request((0..<101).map { _ in UserID(uuid: UUID()) }, actor: actor).profileVisibilityTargetCount == nil)
        #expect(request([try UserID("malformed")], actor: actor).profileVisibilityTargetCount == nil)
        #expect(request([target], actor: try UserID("malformed")).profileVisibilityTargetCount == nil)
    }

    @Test("retry and batching policy come from the typed capability")
    func policyAndIdentity() throws {
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let message = ClientMessageID(uuid: UUID())
        let send = V2RoomRequest.messaging(.sendOperation(try .init(command: .init(
            roomID: room, senderUserID: user, clientMessageID: message, text: "message",
            limits: .init(maxUTF8Bytes: 64)
        ), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)))
        let encoded = try JSONEncoder().encode(send)
        let decoded = try JSONDecoder().decode(V2RoomRequest.self, from: encoded)
        #expect(decoded == send)
        #expect(decoded.roomID == room)
        #expect(decoded.actorUserID == user)
        #expect(decoded.replayPolicy == .durableIdempotent)
        #expect(decoded.hasStableOperationID)
        #expect(!decoded.canShareSendTurn)

        let query = V2RoomRequest.recovery(.init(roomID: room, actorUserID: user, kind: .state))
        #expect(query.roomID == room)
        #expect(query.replayPolicy == .readOnly)
        #expect(!query.hasStableOperationID)
        #expect(!query.canShareSendTurn)
        #expect(try JSONDecoder().decode(V2RoomRequest.self, from: JSONEncoder().encode(query)) == query)
    }

    @Test("trusted safety is distinct from user-authored moderation")
    func trustedPrincipalBoundary() throws {
        let room = RoomID(uuid: UUID())
        let operation = ModerationOperationID(uuid: UUID())
        let request = V2RoomRequest.administration(.trustedSafety(.init(
            roomID: room, operationID: operation, action: .redactMessage,
            messageID: MessageID(uuid: UUID()), expectedMessageRevision: 7, reasonCode: "review"
        )))
        #expect(request.actorUserID == nil)
        #expect(request.roomID == room)
        #expect(request.hasStableOperationID)
        #expect(!request.canShareSendTurn)
    }

    @Test("unknown capabilities and collection queries cannot masquerade as one room turn")
    func unknownDiscriminator() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2RoomRequest.self, from: Data(#"{"futureCapability":{}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2RoomRequest.self, from: Data(#"{"recovery":{"roomIDs":[],"actorUserID":{"rawValue":"user"}}}"#.utf8))
        }
    }

    @Test("unavailable and retry survive a per-room recovery reply")
    func resultDistinctions() throws {
        let values: [V2RoomResponse] = [
            .recovery(.state(.unavailable)), .recovery(.state(.retry)),
            .recovery(.latestVisible(.unavailable)), .recovery(.latestVisible(.retry)),
        ]
        for value in values {
            #expect(try JSONDecoder().decode(V2RoomResponse.self, from: JSONEncoder().encode(value)) == value)
        }
    }
}
