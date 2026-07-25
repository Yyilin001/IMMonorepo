import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 room write service")
struct V2SendMessageServiceTests {
    @Test("authenticated actor is persisted as the message sender and retry is idempotent")
    func authenticatedActorAndRetry() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try V2MessageCommandLimits(maxUTF8Bytes: 64),
            idFactory: V2AcceptanceIDFactory(makeUUID: fixture.nextUUID),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(
            roomID: fixture.roomID,
            actorUserID: fixture.senderID,
            clientMessageID: fixture.clientMessageID,
            text: "hello V2"
        )

        let first = try await service.send(request)
        let retry = try await service.send(request)

        guard case .accepted(let accepted) = first else {
            Issue.record("first send must be accepted")
            return
        }
        #expect(accepted.senderUserID == fixture.senderID)
        #expect(retry == .idempotent(accepted))
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 2)
        #expect(state.0.admission.commandWindow.used == 1)
    }

    @Test("a rejected admission leaves the room state untouched")
    func rateLimitDoesNotMutateState() async throws {
        var fixture = try Fixture()
        fixture.profile = try RoomCapacityProfile(
            maxEligibleMembers: 10,
            maxCommandsPerWindow: 0,
            maxFanoutUnitsPerWindow: 10,
            maxOutstandingFanoutUnits: 10,
            maxOutstandingPlans: 10,
            maxEnumerationPageSize: 10,
            maxPlannerConcurrency: 1,
            maxDeliveryConcurrency: 1,
            retryAfterSeconds: 7
        )
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID])
        let fixedNow = fixture.now
        let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), limits: try .init(maxUTF8Bytes: 64), now: { fixedNow })

        let outcome = try await service.send(.init(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "blocked"))
        #expect(outcome == .rateLimited(retryAfterSeconds: 7))
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
        #expect(state.0.admission.commandWindow.used == 0)
    }

    @Test("a new command from a non-member is rejected before capacity is consumed")
    func nonMemberCannotSend() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )

        await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
            _ = try await service.send(.init(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "forbidden"))
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
        #expect(state.0.admission.commandWindow.used == 0)
    }

    @Test("a room cannot use a process-wide profile with the wrong persisted identifier")
    func capacityProfileMustMatchRoomBinding() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID], capacityProfileID: "standard")
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "premium", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "wrong profile")

        await #expect(throws: V2RoomWriteStoreError.capacityProfileMismatch) {
            try await service.send(request)
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
    }
}

private struct Fixture: Sendable {
    let roomID = try! RoomID("00000000-0000-0000-0000-000000000001")
    let senderID = try! UserID("00000000-0000-0000-0000-000000000002")
    let clientMessageID = try! ClientMessageID("00000000-0000-0000-0000-000000000003")
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    var profile: RoomCapacityProfile
    let roomState: V2RoomCommandState
    let shardState: ShardAdmissionState

    init() throws {
        profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 10, maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 7)
        roomState = try V2RoomCommandState(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), outstandingFanoutUnits: 0, outstandingPlans: 0))
        shardState = try ShardAdmissionState(lease: .init(id: try ShardAdmissionLeaseID("00000000-0000-0000-0000-000000000004"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10), outstandingFanoutUnits: 0, outstandingPlans: 0)
    }

    func nextUUID() -> UUID { UUID() }
}
