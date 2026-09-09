import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 room membership service")
struct V2RoomMembershipServiceTests {
    @Test("authenticated actor and immutable operation data reach the membership store")
    func forwardsAuthenticatedChange() async throws {
        let store = MembershipStoreSpy()
        let service = V2RoomMembershipService(
            store: store,
            capacityProfile: try profile(),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let request = try request()

        let result = try await service.change(request)

        guard case .changed(let change) = result else {
            Issue.record("expected change")
            return
        }
        let captured = try #require(await store.command())
        #expect(captured.actorUserID == request.actorUserID)
        #expect(captured.operationID == request.operationID)
        #expect(captured.expectedMembershipRevision == 4)
        #expect(UUID(uuidString: change.eventID.rawValue) != nil)
        #expect(UUID(uuidString: change.fanoutPlanID.rawValue) != nil)
    }

    @Test("invalid self-targeting is rejected before the persistence boundary")
    func rejectsInvalidCommandBeforeStore() async throws {
        let store = MembershipStoreSpy()
        let service = V2RoomMembershipService(store: store, capacityProfile: try profile())
        let user = try UserID("00000000-0000-0000-0000-000000000703")
        let invalid = V2AuthenticatedMembershipChange(roomID: try .init("00000000-0000-0000-0000-000000000704"), actorUserID: user, operationID: try .init("00000000-0000-0000-0000-000000000705"), targetUserID: user, action: .remove, expectedMembershipRevision: 1)

        await #expect(throws: V2RoomMembershipValidationError.selfTargetingNotAllowed) {
            _ = try await service.change(invalid)
        }
        #expect(await store.command() == nil)
    }

    private func request() throws -> V2AuthenticatedMembershipChange {
        .init(roomID: try .init("00000000-0000-0000-0000-000000000706"), actorUserID: try .init("00000000-0000-0000-0000-000000000707"), operationID: try .init("00000000-0000-0000-0000-000000000708"), targetUserID: try .init("00000000-0000-0000-0000-000000000709"), action: .add, expectedMembershipRevision: 4)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1))
    }
}

private actor MembershipStoreSpy: V2RoomMembershipStore {
    private var captured: V2ChangeRoomMembershipCommand?

    func change(command: V2ChangeRoomMembershipCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2RoomMembershipChangeOutcome {
        captured = command
        return .changed(try .init(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action, membershipRevision: command.expectedMembershipRevision + 1, roomSequence: 8, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }

    func command() -> V2ChangeRoomMembershipCommand? { captured }
}
