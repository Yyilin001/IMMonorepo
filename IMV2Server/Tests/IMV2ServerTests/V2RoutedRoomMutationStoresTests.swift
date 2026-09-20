import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 routed room mutation stores")
struct V2RoutedRoomMutationStoresTests {
    @Test("membership uses control identity snapshot and selected room owner")
    func routesControlValidatedMembership() async throws {
        let roomID = try RoomID(
            "00000000-0000-0000-0000-00000000d001"
        )
        let actor = try UserID(
            "00000000-0000-0000-0000-00000000d002"
        )
        let target = try UserID(
            "00000000-0000-0000-0000-00000000d003"
        )
        let first = RoutedMutationStoreSpy()
        let second = RoutedMutationStoreSpy()
        let identities = RoutedMembershipIdentityValidator()
        let store = try V2RoutedRoomMembershipStore(
            router: RoutedMutationRouter(routes: [
                roomID: try .init(shardID: "rooms-b", epoch: 4),
            ]),
            stores: ["rooms-a": first, "rooms-b": second],
            identities: identities
        )
        let command = try V2ChangeRoomMembershipCommand(
            roomID: roomID,
            actorUserID: actor,
            operationID: .init(
                "00000000-0000-0000-0000-00000000d004"
            ),
            targetUserID: target,
            action: .add,
            expectedMembershipRevision: 3
        )

        #expect(try await store.change(
            command: command,
            capacityProfile: profile(),
            eventID: .init("00000000-0000-0000-0000-00000000d005"),
            now: .init(timeIntervalSince1970: 100)
        ) == .targetAlreadyMember)
        #expect(await first.membershipCommand() == nil)
        #expect(await second.membershipCommand() == command)
        #expect(try await second.selectedRoute() == .init(shardID: "rooms-b", epoch: 4))
        #expect(await second.identitySnapshot() == .init(
            actorUserID: actor,
            targetUserID: target,
            actorIsActive: true,
            targetIsActive: true
        ))
        #expect(await identities.requestedUsers() == [actor, target])
    }

    @Test("edit withdrawal and reaction select the same durable room owner")
    func routesMessageMutations() async throws {
        let roomID = try RoomID(
            "00000000-0000-0000-0000-00000000d011"
        )
        let actor = try UserID(
            "00000000-0000-0000-0000-00000000d012"
        )
        let messageID = try MessageID(
            "00000000-0000-0000-0000-00000000d013"
        )
        let first = RoutedMutationStoreSpy()
        let second = RoutedMutationStoreSpy()
        let router = RoutedMutationRouter(routes: [
            roomID: try .init(shardID: "rooms-b", epoch: 9),
        ])
        let stores: [String: RoutedMutationStoreSpy] = [
            "rooms-a": first,
            "rooms-b": second,
        ]
        let edit = try V2RoutedMessageEditStore(
            router: router,
            stores: stores
        )
        let withdrawal = try V2RoutedMessageWithdrawalStore(
            router: router,
            stores: stores
        )
        let reaction = try V2RoutedMessageReactionStore(
            router: router,
            stores: stores
        )

        _ = try await edit.edit(
            command: .init(
                roomID: roomID,
                actorUserID: actor,
                operationID: .init(
                    "00000000-0000-0000-0000-00000000d014"
                ),
                messageID: messageID,
                expectedMessageRevision: 1,
                text: "edited",
                maximumUTF8Bytes: 64
            ),
            capacityProfile: profile(),
            eventID: .init("00000000-0000-0000-0000-00000000d015"),
            now: .init(timeIntervalSince1970: 101)
        )
        _ = try await withdrawal.withdraw(
            command: .init(
                roomID: roomID,
                actorUserID: actor,
                operationID: .init(
                    "00000000-0000-0000-0000-00000000d017"
                ),
                messageID: messageID,
                expectedMessageRevision: 2
            ),
            capacityProfile: profile(),
            eventID: .init("00000000-0000-0000-0000-00000000d018"),
            now: .init(timeIntervalSince1970: 102)
        )
        _ = try await reaction.change(
            command: .init(
                roomID: roomID,
                actorUserID: actor,
                operationID: .init(
                    "00000000-0000-0000-0000-00000000d01a"
                ),
                messageID: messageID,
                reaction: "👍",
                action: .add
            ),
            capacityProfile: profile(),
            eventID: .init("00000000-0000-0000-0000-00000000d01b"),
            now: .init(timeIntervalSince1970: 103)
        )

        #expect(await first.messageMutationCount() == 0)
        #expect(await second.messageMutationCount() == 3)
        #expect(try await second.selectedMessageRoutes() == Array(repeating: .init(shardID: "rooms-b", epoch: 9), count: 3))
        #expect(await router.requestedRooms() == [roomID, roomID, roomID])
    }

    @Test("co-located logical shards retain the selected epoch")
    func retainsRouteWhenEveryShardSharesOnePhysicalStore() async throws {
        let store = RoutedMutationStoreSpy()
        let roomID = try RoomID("00000000-0000-0000-0000-00000000d021")
        let router = RoutedMutationRouter(routes: [roomID: try .init(shardID: "rooms-a", epoch: 7)])
        let routed = try V2RoutedMessageEditStore(
            router: router,
            stores: ["rooms-a": store, "rooms-b": store],
            physicalStoreKeyByShard: [
                "rooms-a": "postgres-one",
                "rooms-b": "postgres-one",
            ]
        )

        #expect(try await routed.edit(
            command: .init(
                roomID: .init(
                    "00000000-0000-0000-0000-00000000d021"
                ),
                actorUserID: .init(
                    "00000000-0000-0000-0000-00000000d022"
                ),
                operationID: .init(
                    "00000000-0000-0000-0000-00000000d023"
                ),
                messageID: .init(
                    "00000000-0000-0000-0000-00000000d024"
                ),
                expectedMessageRevision: 1,
                text: "same owner",
                maximumUTF8Bytes: 64
            ),
            capacityProfile: profile(),
            eventID: .init("00000000-0000-0000-0000-00000000d025"),
            now: .init(timeIntervalSince1970: 104)
        ) == .alreadyWithdrawn)
        #expect(await router.requestedRooms() == [roomID])
        #expect(try await store.selectedMessageRoutes() == [.init(shardID: "rooms-a", epoch: 7)])
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(
            id: "standard",
            limits: .init(
                maxEligibleMembers: 100,
                maxCommandsPerWindow: 100,

                retryAfterSeconds: 1
            )
        )
    }
}

private actor RoutedMutationRouter: V2RoomShardRouting {
    private let routesByRoom: [RoomID: V2RoomShardRoute]
    private var requested: [RoomID] = []

    init(routes: [RoomID: V2RoomShardRoute]) {
        routesByRoom = routes
    }

    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        requested.append(roomID)
        guard let route = routesByRoom[roomID] else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return route
    }

    func requestedRooms() -> [RoomID] { requested }
}

private actor RoutedMembershipIdentityValidator:
    V2MembershipIdentitySnapshotValidating {
    private var users: [UserID] = []

    func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) -> V2MembershipIdentitySnapshot {
        users = [actorUserID, targetUserID]
        return .init(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            actorIsActive: true,
            targetIsActive: true
        )
    }

    func requestedUsers() -> [UserID] { users }
}

private actor RoutedMutationStoreSpy:
    V2ControlValidatedRoomMembershipStore,
    V2OwnerValidatedMessageEditStore,
    V2OwnerValidatedMessageWithdrawalStore,
    V2OwnerValidatedMessageReactionStore {
    private var membership: V2ChangeRoomMembershipCommand?
    private var snapshot: V2MembershipIdentitySnapshot?
    private var route: V2RoomShardRoute?
    private var messageMutations = 0
    private var messageRoutes: [V2RoomShardRoute] = []

    func change(
        command _: V2ChangeRoomMembershipCommand,
        capacityProfile _: V2CapacityProfile,
        eventID _: EventID,
        now _: Date
    ) throws -> V2RoomMembershipChangeOutcome {
        throw V2RoomMembershipStoreError.corruptPersistenceState
    }

    func selectedRoute() -> V2RoomShardRoute? { route }

    func changeControlValidated(
        command: V2ChangeRoomMembershipCommand,
        ownerRoute: V2RoomShardRoute,
        identitySnapshot: V2MembershipIdentitySnapshot,
        capacityProfile _: V2CapacityProfile,
        eventID _: EventID,
        now _: Date
    ) -> V2RoomMembershipChangeOutcome {
        membership = command
        route = ownerRoute
        snapshot = identitySnapshot
        return .targetAlreadyMember
    }

    func editOwnerValidated(
        command _: V2EditMessageCommand,
        ownerRoute: V2RoomShardRoute,
        capacityProfile _: V2CapacityProfile,
        eventID _: EventID,
        now _: Date
    ) -> V2MessageEditOutcome {
        messageMutations += 1
        messageRoutes.append(ownerRoute)
        return .alreadyWithdrawn
    }

    func withdrawOwnerValidated(
        command _: V2WithdrawMessageCommand,
        ownerRoute: V2RoomShardRoute,
        capacityProfile _: V2CapacityProfile,
        eventID _: EventID,
        now _: Date
    ) -> V2MessageWithdrawalOutcome {
        messageMutations += 1
        messageRoutes.append(ownerRoute)
        return .alreadyWithdrawn
    }

    func changeOwnerValidated(
        command _: V2ChangeMessageReactionCommand,
        ownerRoute: V2RoomShardRoute,
        capacityProfile _: V2CapacityProfile,
        eventID _: EventID,
        now _: Date
    ) -> V2MessageReactionOutcome {
        messageMutations += 1
        messageRoutes.append(ownerRoute)
        return .alreadyInDesiredState
    }

    func membershipCommand() -> V2ChangeRoomMembershipCommand? { membership }
    func identitySnapshot() -> V2MembershipIdentitySnapshot? { snapshot }
    func messageMutationCount() -> Int { messageMutations }
    func selectedMessageRoutes() -> [V2RoomShardRoute] { messageRoutes }
}
