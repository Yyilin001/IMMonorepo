import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 group messaging service")
struct V2GroupMessagingServiceTests {
    @Test("forwards an atomic, canonical group creation command")
    func forwardsCreation() async throws {
        let store = GroupStoreSpy()
        let service = try V2GroupMessagingService(
            store: store,
            capacityProfile: try profile(maxMembers: 4),
            roomShardID: "rooms-primary",
            identifiers: .init(makeUUID: { UUID() }),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let owner = try UserID("00000000-0000-0000-0000-000000000951")
        let member = try UserID("00000000-0000-0000-0000-000000000952")

        let result = try await service.create(
            actorUserID: owner,
            operationID: .init("00000000-0000-0000-0000-000000000953"),
            title: " 项目群 ",
            initialMemberUserIDs: [member]
        )

        guard case .created(let room) = result else { Issue.record("expected group"); return }
        #expect(UUID(uuidString: room.roomID.rawValue) != nil)
        let command = try #require(await store.command())
        #expect(command.title == "项目群")
        #expect(command.allMemberUserIDs == [owner, member])
    }

    @Test("rejects a membership count beyond the assigned profile before persistence")
    func rejectsOverProfileLimit() async throws {
        let store = GroupStoreSpy()
        let service = try V2GroupMessagingService(store: store, capacityProfile: try profile(maxMembers: 1), roomShardID: "rooms-primary")
        let owner = try UserID("00000000-0000-0000-0000-000000000955")
        let member = try UserID("00000000-0000-0000-0000-000000000956")

        let result = try await service.create(
            actorUserID: owner,
            operationID: .init("00000000-0000-0000-0000-000000000957"),
            title: "群",
            initialMemberUserIDs: [member]
        )

        #expect(result == .memberLimitReached)
        #expect(await store.command() == nil)
    }

    private func profile(maxMembers: Int) throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: maxMembers, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1))
    }
}

private actor GroupStoreSpy: V2GroupMessagingStore {
    private var captured: V2CreateGroupRoomCommand?

    func create(command: V2CreateGroupRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID _: String, roomID: RoomID, eventID _: EventID, planID _: FanoutPlanID, now: Date) -> V2CreateGroupRoomOutcome {
        captured = command
        return .created(.init(roomID: roomID, ownerUserID: command.actorUserID, title: command.title, memberUserIDs: command.allMemberUserIDs, createdAt: now))
    }

    func command() -> V2CreateGroupRoomCommand? {
        captured
    }
}
