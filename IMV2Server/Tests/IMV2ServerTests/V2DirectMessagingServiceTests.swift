import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 direct messaging service")
struct V2DirectMessagingServiceTests {
    @Test("opens a pair with authenticated actor and durable operation")
    func forwardsOpen() async throws {
        let store = DirectStoreSpy()
        let service = try V2DirectMessagingService(
            store: store,
            capacityProfile: try profile(),
            roomShardID: "rooms-primary",
            identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000804")! }),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let actor = try UserID("00000000-0000-0000-0000-000000000801")
        let target = try UserID("00000000-0000-0000-0000-000000000802")
        let operation = try DirectRoomOperationID("00000000-0000-0000-0000-000000000803")

        let result = try await service.open(actorUserID: actor, operationID: operation, targetUserID: target)

        guard case .opened(let room) = result else { Issue.record("expected room"); return }
        #expect(room.roomID.rawValue == "00000000-0000-0000-0000-000000000804")
        let captured = try #require(await store.openCommand())
        #expect(captured.actorUserID == actor)
        #expect(captured.operationID == operation)
        #expect(captured.targetUserID == target)
    }

    @Test("unordered direct pairs choose one stable shard from a bounded pool")
    func selectsStableShardForPair() async throws {
        let store = DirectStoreSpy()
        let service = try V2DirectMessagingService(
            store: store,
            capacityProfile: try profile(),
            roomShardID: "rooms-00, rooms-01,rooms-02,rooms-03"
        )
        let first = try UserID("00000000-0000-0000-0000-000000000811")
        let second = try UserID("00000000-0000-0000-0000-000000000812")

        _ = try await service.open(
            actorUserID: first,
            operationID: try .init("00000000-0000-0000-0000-000000000813"),
            targetUserID: second
        )
        _ = try await service.open(
            actorUserID: second,
            operationID: try .init("00000000-0000-0000-0000-000000000814"),
            targetUserID: first
        )

        let shards = await store.openShards()
        #expect(shards.count == 2)
        #expect(shards[0] == shards[1])
        #expect(Set(["rooms-00", "rooms-01", "rooms-02", "rooms-03"]).contains(shards[0]))
    }

    @Test("rejects malformed or duplicate direct shard pools")
    func rejectsInvalidShardPools() throws {
        #expect(throws: V2DirectMessagingPolicyError.invalidLimit) {
            _ = try V2DirectMessagingService(
                store: DirectStoreSpy(),
                capacityProfile: try profile(),
                roomShardID: "rooms-00,,rooms-01"
            )
        }
        #expect(throws: V2DirectMessagingPolicyError.invalidLimit) {
            _ = try V2DirectMessagingService(
                store: DirectStoreSpy(),
                capacityProfile: try profile(),
                roomShardID: "rooms-00,rooms-00"
            )
        }
    }

    @Test("rejects opening a direct room with oneself before persistence")
    func rejectsSelfTarget() async throws {
        let store = DirectStoreSpy()
        let service = try V2DirectMessagingService(store: store, capacityProfile: try profile(), roomShardID: "rooms-primary")
        let user = try UserID("00000000-0000-0000-0000-000000000805")
        await #expect(throws: V2DirectMessagingValidationError.selfTargetingNotAllowed) {
            _ = try await service.open(actorUserID: user, operationID: try .init("00000000-0000-0000-0000-000000000806"), targetUserID: user)
        }
        #expect(await store.openCommand() == nil)
    }

    @Test("forwards device-independent stranger-message permission")
    func forwardsPreference() async throws {
        let store = DirectStoreSpy()
        let service = try V2DirectMessagingService(store: store, capacityProfile: try profile(), roomShardID: "rooms-primary")
        let actor = try UserID("00000000-0000-0000-0000-000000000807")
        let operation = try StrangerMessagePreferenceOperationID("00000000-0000-0000-0000-000000000808")

        let result = try await service.setStrangerMessagePermission(actorUserID: actor, operationID: operation, permission: .deny)

        guard case .updated(let permission, _) = result else { Issue.record("expected preference update"); return }
        #expect(permission == .deny)
        #expect(await store.preferenceCommand()?.permission == .deny)
    }

    @Test("forwards device-independent add permission")
    func forwardsUserAddPreference() async throws {
        let store = DirectStoreSpy()
        let service = try V2DirectMessagingService(store: store, capacityProfile: try profile(), roomShardID: "rooms-primary")
        let actor = try UserID("00000000-0000-0000-0000-000000000809")
        let operation = try UserAddPreferenceOperationID("00000000-0000-0000-0000-00000000080a")

        let result = try await service.setUserAddPermission(actorUserID: actor, operationID: operation, permission: .deny)

        guard case .updated(let permission, _) = result else { Issue.record("expected preference update"); return }
        #expect(permission == .deny)
        #expect(await store.userAddPreferenceCommand()?.permission == .deny)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1))
    }
}

private actor DirectStoreSpy: V2DirectMessagingStore {
    private var capturedOpen: V2OpenDirectRoomCommand?
    private var capturedOpenShards: [String] = []
    private var capturedPreference: V2SetStrangerMessagePermissionCommand?
    private var capturedUserAddPreference: V2SetUserAddPermissionCommand?

    func open(command: V2OpenDirectRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID: String, roomID: RoomID, now: Date) throws -> V2OpenDirectRoomOutcome {
        capturedOpen = command
        capturedOpenShards.append(roomShardID)
        return .opened(.init(roomID: roomID, actorUserID: command.actorUserID, targetUserID: command.targetUserID, createdAt: now))
    }

    func setStrangerMessagePermission(command: V2SetStrangerMessagePermissionCommand, now: Date) throws -> V2SetStrangerMessagePermissionOutcome {
        capturedPreference = command
        return .updated(permission: command.permission, updatedAt: now)
    }

    func setUserAddPermission(command: V2SetUserAddPermissionCommand, now: Date) throws -> V2SetUserAddPermissionOutcome {
        capturedUserAddPreference = command
        return .updated(permission: command.permission, updatedAt: now)
    }

    func openCommand() -> V2OpenDirectRoomCommand? { capturedOpen }
    func openShards() -> [String] { capturedOpenShards }
    func preferenceCommand() -> V2SetStrangerMessagePermissionCommand? { capturedPreference }
    func userAddPreferenceCommand() -> V2SetUserAddPermissionCommand? { capturedUserAddPreference }
}
