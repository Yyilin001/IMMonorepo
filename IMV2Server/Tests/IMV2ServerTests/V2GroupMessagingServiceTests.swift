import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 group messaging service")
struct V2GroupMessagingServiceTests {
    @Test("Staged command counts reserve room for the owner without overflowing",
          arguments: [Int.min, -1, 0, 99_999, Int.max - 1, Int.max])
    func stagedCommandCountBounds(count: Int) throws {
        let owner = UserID(uuid: UUID()), operation = GroupRoomOperationID(uuid: UUID())
        if count < 0 || count == Int.max {
            #expect(throws: V2GroupMessagingPolicyError.invalidInitialMembership) {
                try V2StagedGroupRoomCommand(actorUserID: owner, operationID: operation,
                    title: "boundary", capacityClass: .large, stagedMemberCount: count)
            }
        } else {
            let command = try V2StagedGroupRoomCommand(actorUserID: owner, operationID: operation,
                title: "boundary", capacityClass: .large, stagedMemberCount: count)
            #expect(command.allMemberCount == count + 1)
        }
    }

    @Test("Staged service rejects malformed and oversized counts before persistence",
          arguments: [Int.min, -1, 100_000, Int.max - 1, Int.max])
    func stagedServiceCountBounds(count: Int) async throws {
        let store = GroupStoreSpy()
        let service = try V2GroupMessagingService(store: store,
            capacityProfile: profile(maxMembers: 100_000), roomShardID: "rooms-primary")
        if count < 0 {
            await #expect(throws: V2GroupMessagingPolicyError.invalidInitialMembership) {
                try await service.createStaged(actorUserID: .init(uuid: UUID()),
                    operationID: .init(uuid: UUID()), title: "boundary", stagedMemberCount: count)
            }
        } else {
            #expect(try await service.createStaged(actorUserID: .init(uuid: UUID()),
                operationID: .init(uuid: UUID()), title: "boundary", stagedMemberCount: count) == .memberLimitReached)
        }
        #expect(await store.command() == nil)
    }

    @Test("Manifest page numbers fit the PostgreSQL integer column",
          arguments: [Int.min, -1, 0, Int(Int32.max), Int(Int32.max) + 1, Int.max])
    func manifestPageNumberBounds(number: Int) throws {
        let members = [UserID(uuid: UUID())]
        if number < 0 || number > Int(Int32.max) {
            #expect(throws: V2GroupRoomCreationIntentStoreError.invalidIntent) {
                try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)
            }
        } else {
            let page = try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)
            #expect(page.pageNumber == number)
            #expect(page.digest.count == 32)
            #expect(page == (try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)))
        }
    }

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
        #expect(command.capacityClass == .standard)
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

    @Test("derives the immutable delivery mode at the 5,000-member boundary")
    func derivesCapacityClassAtBoundary() async throws {
        let store = GroupStoreSpy()
        let service = try V2GroupMessagingService(
            store: store,
            capacityProfile: try profile(maxMembers: 100_000),
            roomShardID: "rooms-primary"
        )
        // Keep the owner outside the generated 1...5,000 member range.
        let owner = try UserID("00000000-0000-0000-0000-0000000fffff")

        let standard = try await service.create(
            actorUserID: owner,
            operationID: .init("00000000-0000-0000-0000-000000000961"),
            title: "五千人群",
            initialMemberUserIDs: try members(count: 4_999)
        )
        guard case .created = standard else { Issue.record("expected standard group"); return }
        #expect(try #require(await store.command()).capacityClass == .standard)

        let hybrid = try await service.create(
            actorUserID: owner,
            operationID: .init("00000000-0000-0000-0000-000000000962"),
            title: "五千零一人群",
            initialMemberUserIDs: try members(count: 5_000)
        )
        guard case .created = hybrid else { Issue.record("expected hybrid group"); return }
        #expect(try #require(await store.command()).capacityClass == .large)
    }

    private func profile(maxMembers: Int) throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: maxMembers, maxCommandsPerWindow: 10,    retryAfterSeconds: 1))
    }

    private func members(count: Int) throws -> [UserID] {
        try (1...count).map { value in
            try .init(String(format: "00000000-0000-0000-0000-%012x", value))
        }
    }
}

private actor GroupStoreSpy: V2GroupMessagingStore {
    private var captured: V2CreateGroupRoomCommand?

    func create(command: V2CreateGroupRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID _: String, roomID: RoomID, eventID _: EventID, now: Date) throws -> V2CreateGroupRoomOutcome {
        captured = command
        return .created(try .init(roomID: roomID, ownerUserID: command.actorUserID, title: command.title, capacityClass: command.capacityClass, memberUserIDs: command.allMemberUserIDs, createdAt: now))
    }

    func command() -> V2CreateGroupRoomCommand? {
        captured
    }
}
