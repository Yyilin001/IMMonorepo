@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 room actor media authorization port")
struct V2RoomActorMediaAuthorizationPortTests {
    @Test("cohort replies must preserve every viewer, target and common room observation",
          arguments: ["valid", "reordered", "missing", "duplicate", "unversioned-denial", "foreign-target",
                      "wrong-actor", "wrong-room", "mixed-revision", "mixed-activation", "mixed-observation", "invalid-expiry", "oversized"])
    func cohortReplyValidation(scenario: String) async throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID()), now = Date()
        let token = V2RoomActivationToken(roomID: room, owner: try .init(shardID: "cohort", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
        let requests = (0..<2).map { _ in V2ActorProfileVisibilityBatchWire(roomID: room,
            actorUserID: .init(uuid: UUID()), roomKind: .memberRoom, targetUserIDs: [target]) }
        let request = V2ActorProfileVisibilityCohortWire(roomID: room, requests: requests)
        func proof(_ input: V2ActorProfileVisibilityBatchWire, targets: [UserID],
                   activation: V2RoomActivationToken? = nil, revision: Int64 = 1,
                   observed: Date? = nil, expiry: Date? = nil) -> V2ActorProfileVisibilityBatchSnapshotWire {
            .init(request: input, activation: activation ?? token, membershipRevision: revision,
                visibleTargetUserIDs: targets, observedAt: observed ?? now,
                activationExpiresAt: expiry ?? now.addingTimeInterval(20), permissionRevision: 1)
        }
        let allowed = proof(requests[0], targets: [target]), denied = proof(requests[1], targets: [])
        let response: V2RoomMediaAuthorizationResult
        switch scenario {
        case "valid": response = .profilesVisibleCohort([allowed, denied])
        case "reordered": response = .profilesVisibleCohort([denied, allowed])
        case "missing": response = .profilesVisibleCohort([allowed])
        case "duplicate": response = .profilesVisibleCohort([allowed, allowed])
        case "unversioned-denial": response = .notVisible
        case "foreign-target": response = .profilesVisibleCohort([allowed, proof(requests[1], targets: [.init(uuid: UUID())])])
        case "wrong-actor": response = .profilesVisibleCohort([allowed, proof(.init(roomID: room,
            actorUserID: .init(uuid: UUID()), roomKind: .memberRoom, targetUserIDs: [target]), targets: [])])
        case "wrong-room": response = .profilesVisibleCohort([allowed, proof(.init(roomID: .init(uuid: UUID()),
            actorUserID: requests[1].actorUserID, roomKind: .memberRoom, targetUserIDs: [target]), targets: [])])
        case "mixed-revision": response = .profilesVisibleCohort([allowed, proof(requests[1], targets: [], revision: 2)])
        case "mixed-activation": response = .profilesVisibleCohort([allowed, proof(requests[1], targets: [],
            activation: .init(roomID: room, owner: token.owner, activationEpoch: try .init(2), host: token.host))])
        case "mixed-observation": response = .profilesVisibleCohort([allowed, proof(requests[1], targets: [], observed: now.addingTimeInterval(1))])
        case "oversized":
            let large = V2RoomActivationToken(roomID: room,
                owner: try .init(shardID: String(repeating: "s", count: 128 * 1_024), epoch: 0),
                activationEpoch: token.activationEpoch, host: token.host)
            let snapshots = [proof(requests[0], targets: [target], activation: large),
                             proof(requests[1], targets: [], activation: large)]
            #expect(try V2ActorProtobuf.encode(V2RoomResponse.mediaAuthorization(.profilesVisibleCohort(snapshots))).count > 256 * 1_024)
            response = .profilesVisibleCohort(snapshots)
        default: response = .profilesVisibleCohort([allowed, proof(requests[1], targets: [], expiry: now)])
        }
        let deadline = ContinuousClock.now + .seconds(1)
        let port = V2ActorRoomMediaAuthorizationPort { query, budget in
            #expect(query == .profileVisibilityCohort(request) && budget == deadline)
            return response
        }
        if scenario == "valid" {
            #expect(try await port.captureProfiles(request, deadline: deadline) == [allowed, denied])
        } else {
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                try await port.captureProfiles(request, deadline: deadline)
            }
        }
    }

    @Test("invalid multi-viewer input never starts room I/O")
    func invalidCohortInput() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let port = V2ActorRoomMediaAuthorizationPort { _, _ in Issue.record("invalid cohort reached transport"); return .notVisible }
        let values: [[V2ActorProfileVisibilityBatchWire]] = [[],
            [.init(roomID: .init(uuid: UUID()), actorUserID: actor, roomKind: .group, targetUserIDs: [target])],
            [.init(roomID: room, actorUserID: actor, roomKind: .group, targetUserIDs: [target, target])],
            Array(repeating: .init(roomID: room, actorUserID: actor, roomKind: .group, targetUserIDs: [target]), count: 101)]
        for requests in values {
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                try await port.captureProfiles(.init(roomID: room, requests: requests), deadline: .now + .seconds(1))
            }
        }
    }

    @Test("exchange re-queries the room and rejects a changed version")
    func rechecksVersion() async throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let media = MediaID(uuid: UUID()), actor = UserID(uuid: UUID())
        let first = V2ActorMessageMediaVisibilitySnapshotWire(roomID: room,
            messageID: message, mediaID: media, membershipRevision: 2,
            contentRevision: 1, mediaUpdatedAt: Date(timeIntervalSince1970: 123),
            uploadSessionID: UUID())
        let state = V2MediaVisibilityState(value: .visible(first))
        let port = V2ActorRoomMediaAuthorizationPort(query: { query, _ in
            guard query.actorUserID == actor else { return .notVisible }
            return await state.get()
        })
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let request = V2ActorMessageMediaVisibilityWire(roomID: room,
            messageID: message, mediaID: media, actorUserID: actor)
        #expect(try await port.capture(request, deadline: deadline) == first)
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline))
        await state.set(.visible(.init(roomID: room, messageID: message, mediaID: media,
            membershipRevision: 3, contentRevision: 1,
            mediaUpdatedAt: first.mediaUpdatedAt,
            uploadSessionID: first.uploadSessionID)))
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline) == false)
        await state.set(.notVisible)
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline) == false)
    }
}

private actor V2MediaVisibilityState {
    private var value: V2RoomMediaAuthorizationResult
    init(value: V2RoomMediaAuthorizationResult) { self.value = value }
    func get() -> V2RoomMediaAuthorizationResult { value }
    func set(_ next: V2RoomMediaAuthorizationResult) { value = next }
}
