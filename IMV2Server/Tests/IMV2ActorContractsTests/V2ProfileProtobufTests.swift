import Foundation
import IMV2Core
import SwiftProtobuf
import Testing
@testable import IMV2ActorContracts

@Suite("Fixed profile authority Protobuf contracts")
struct V2ProfileProtobufTests {
    private func snapshot(kind: V2ActorProfileVisibilityBatchWire.RoomKind = .group,
                          nickname: String? = "成员😀") throws -> V2ActorProfileVisibilityBatchSnapshotWire {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        return try .init(request: .init(roomID: room, actorUserID: .init(uuid: UUID()), roomKind: kind, targetUserIDs: [target]),
            activation: .init(roomID: room, owner: .init(shardID: "rooms", epoch: 0), activationEpoch: .init(1),
                host: .init(hostID: .init("owner"), incarnationID: UUID())),
            membershipRevision: .max, visibleTargetUserIDs: [target], observedAt: .init(timeIntervalSinceReferenceDate: -0.125),
            activationExpiresAt: .init(timeIntervalSinceReferenceDate: 19.875),
            groupMembers: kind == .group || kind == .memberRoom
                ? [.init(roomID: room, userID: target, groupNickname: nickname, revision: .init(rawValue: UInt64(Int64.max))!)] : [],
            permissionRevision: .max)
    }

    @Test(arguments: ["direct", "group", "memberRoom", "groupJoinReview"])
    func scalarAndCohortPreserveEveryFact(kind: String) throws {
        for name: String? in [nil, "成员😀"] {
            let value = try snapshot(kind: .init(rawValue: kind)!, nickname: name)
            let scalar = V2RoomRequest.mediaAuthorization(.profileVisibilityBatch(value.request))
            let cohort = V2RoomRequest.mediaAuthorization(.profileVisibilityCohort(.init(roomID: value.request.roomID,
                requests: Array(repeating: value.request, count: 100))))
            for request in [scalar, cohort] {
                let bytes = try V2ActorProtobuf.encode(request), wire = try Im_Actor_V1_HotRoomRequest(serializedBytes: bytes)
                #expect(wire.coldValue.isEmpty)
                #expect(try V2ActorProtobuf.decode(V2RoomRequest.self, from: bytes) == request)
                #expect(try bytes.count < V2ActorProtobuf.encodeValue(request).count)
            }
            let denied = V2ActorProfileVisibilityBatchSnapshotWire(request: value.request, activation: value.activation,
                membershipRevision: value.membershipRevision, visibleTargetUserIDs: [], observedAt: value.observedAt,
                activationExpiresAt: value.activationExpiresAt, permissionRevision: value.permissionRevision)
            for response: V2RoomResponse in [.mediaAuthorization(.profilesVisible(value)),
                .mediaAuthorization(.profilesVisibleCohort(Array(repeating: value, count: 99) + [denied]))] {
                let bytes = try V2ActorProtobuf.encode(response), wire = try Im_Actor_V1_HotRoomResponse(serializedBytes: bytes)
                #expect(wire.coldValue.isEmpty)
                #expect(try V2ActorProtobuf.decode(V2RoomResponse.self, from: bytes) == response)
                #expect(try bytes.count < V2ActorProtobuf.encodeValue(response).count)
                #expect(V2ActorPayloadBudget.retainedBytes(of: response) >= bytes.count)
            }
        }
    }

    @Test func obsoleteGenericBranchesAndUnknownFieldsAreRejected() throws {
        let value = try snapshot()
        for request: V2RoomRequest in [.mediaAuthorization(.profileVisibilityBatch(value.request)),
            .mediaAuthorization(.profileVisibilityCohort(.init(roomID: value.request.roomID, requests: [value.request])))] {
            var wire = Im_Actor_V1_HotRoomRequest(); wire.coldValue = try V2ActorProtobuf.encodeValue(request)
            #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: wire.serializedData()) }
        }
        for response: V2RoomResponse in [.mediaAuthorization(.profilesVisible(value)), .mediaAuthorization(.profilesVisibleCohort([value]))] {
            var wire = Im_Actor_V1_HotRoomResponse(); wire.coldValue = try V2ActorProtobuf.encodeValue(response)
            #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomResponse.self, from: wire.serializedData()) }
        }
        var bytes = try Im_Actor_V1_HotProfileRead(value.request).serializedData()
        bytes.append(contentsOf: [0xA0, 0x06, 1])
        var wire = Im_Actor_V1_HotRoomRequest(); wire.profileRead = try .init(serializedBytes: bytes)
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: wire.serializedData()) }
        bytes = try Im_Actor_V1_HotProfileSnapshot(value).serializedData(); bytes.append(contentsOf: [0xA0, 0x06, 1])
        var reply = Im_Actor_V1_HotRoomResponse(); reply.profileSnapshot = try .init(serializedBytes: bytes)
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomResponse.self, from: reply.serializedData()) }
    }

    @Test func invalidRequestShapesFailBeforeAdmission() throws {
        let value = try snapshot(), valid = Im_Actor_V1_HotProfileRead(value.request)
        var cases: [Im_Actor_V1_HotProfileRead] = []
        var bad = valid; bad.targetIds = []; cases.append(bad)
        bad = valid; bad.targetIds += bad.targetIds; cases.append(bad)
        bad = valid; bad.targetIds = (0..<101).map { _ in UUID().uuidString }; cases.append(bad)
        bad = valid; bad.actorID = "invalid"; cases.append(bad)
        bad = valid; bad.roomID = "invalid"; cases.append(bad)
        bad = valid; bad.targetIds = ["invalid"]; cases.append(bad)
        bad = valid; bad.roomKind = "future"; cases.append(bad)
        for item in cases { #expect(throws: (any Error).self) { try item.model() } }
        var cohort = Im_Actor_V1_HotProfileCohort(); cohort.roomID = valid.roomID
        for requests in [[], Array(repeating: valid, count: 101)] {
            cohort.requests = requests; #expect(throws: (any Error).self) { try cohort.model() }
        }
        bad = valid; bad.targetIds.append(UUID().uuidString)
        cohort.requests = Array(repeating: bad, count: 51)
        #expect(throws: (any Error).self) { try cohort.model() }
        cohort.requests = [valid]; cohort.roomID = UUID().uuidString
        #expect(throws: (any Error).self) { try cohort.model() }
    }

    @Test func invalidProofFactsCannotBeDecodedAsGrants() throws {
        let valid = Im_Actor_V1_HotProfileSnapshot(try snapshot())
        var cases: [Im_Actor_V1_HotProfileSnapshot] = []
        var bad = valid; bad.clearRequest(); cases.append(bad)
        bad = valid; bad.clearActivation(); cases.append(bad)
        bad = valid; bad.membershipRevision = -1; cases.append(bad)
        bad = valid; bad.permissionRevision = -1; cases.append(bad)
        bad = valid; bad.clearObservedAtReferenceSeconds(); cases.append(bad)
        bad = valid; bad.clearExpiresAtReferenceSeconds(); cases.append(bad)
        bad = valid; bad.observedAtReferenceSeconds = .nan; cases.append(bad)
        bad = valid; bad.expiresAtReferenceSeconds = .infinity; cases.append(bad)
        bad = valid; bad.expiresAtReferenceSeconds = bad.observedAtReferenceSeconds; cases.append(bad)
        bad = valid; bad.activation.roomID = UUID().uuidString; cases.append(bad)
        bad = valid; bad.visibleTargetIds += bad.visibleTargetIds; cases.append(bad)
        bad = valid; bad.visibleTargetIds = [UUID().uuidString]; cases.append(bad)
        bad = valid; bad.groupMembers += bad.groupMembers; cases.append(bad)
        bad = valid; bad.groupMembers[0].nickname = "  name  "; cases.append(bad)
        bad = valid; bad.groupMembers[0].nickname = ""; cases.append(bad)
        bad = valid; bad.groupMembers[0].revision = 0; cases.append(bad)
        bad = valid; bad.groupMembers[0].revision = .max; cases.append(bad)
        bad = valid; bad.groupMembers[0].roomID = UUID().uuidString; cases.append(bad)
        bad = valid; bad.request.roomKind = "direct"; cases.append(bad)
        for item in cases { #expect(throws: (any Error).self) { try item.model() } }
        var cohort = Im_Actor_V1_HotProfileSnapshots(); cohort.snapshots = [valid, valid]
        cohort.snapshots[1].permissionRevision = 0
        #expect(throws: (any Error).self) { try cohort.model() }
        cohort.snapshots = Array(repeating: valid, count: 101)
        #expect(throws: (any Error).self) { try cohort.model() }
    }

    @Test func responseMemoryCostIncludesAllRetainedValues() throws {
        let value = try snapshot()
        func cost(_ values: [V2ActorProfileVisibilityBatchSnapshotWire]) -> Int {
            V2ActorPayloadBudget.retainedBytes(of: V2RoomResponse.mediaAuthorization(.profilesVisibleCohort(values)))
        }
        #expect(cost(Array(repeating: value, count: 100)) <= 256 * 1_024)
        #expect(cost(Array(repeating: value, count: 200)) > cost(Array(repeating: value, count: 100)))
        var wire = Im_Actor_V1_HotProfileSnapshot(value)
        let original = V2ActorPayloadBudget.retainedBytes(of: value)
        wire.groupMembers[0].nickname = String(repeating: "😀", count: 16)
        #expect(try V2ActorPayloadBudget.retainedBytes(of: wire.model()) > original)
        wire.request.targetIds += (0..<99).map { _ in UUID().uuidString }
        let targets = try wire.model()
        #expect(V2ActorPayloadBudget.retainedBytes(of: targets) > original + 99 * 64)
        wire.visibleTargetIds = wire.request.targetIds
        #expect(try V2ActorPayloadBudget.retainedBytes(of: wire.model()) > V2ActorPayloadBudget.retainedBytes(of: targets) + 99 * 64)
    }
}
