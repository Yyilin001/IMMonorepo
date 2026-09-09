import Foundation
import IMV2Core
import IMV2Server
import Testing

@Suite("Routed room write store")
struct V2RoutedRoomWriteStoreTests {
    @Test("single physical owner preserves distinct direct and group routes for scalar writes")
    func colocatedDirectAndGroupScalarRoutes() async throws {
        let requests = try makeRequests(count: 2)
        let routes = try [V2RoomShardRoute(shardID: "direct-00", epoch: 4), V2RoomShardRoute(shardID: "group-00", epoch: 7)]
        let router = TestRoomRouter(routes: Dictionary(uniqueKeysWithValues: zip(requests.map { $0.command.roomID }, routes)))
        let owner = RecordingAtomicStore()
        let routed = try V2RoutedRoomWriteStore(router: router, stores: ["direct-00": owner, "group-00": owner], physicalStoreKeyByShard: ["direct-00": "local", "group-00": "local"])
        for request in requests {
            _ = try await routed.accept(command: request.command, capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)
        }
        #expect(await router.singleRouteCallCount() == 2)
        #expect(await owner.capturedRoutes() == routes)
    }

    @Test("distinct physical owners receive independent atomic append batches")
    func distinctOwnersReceiveIndependentBatches() async throws {
        let requests = try makeRequests(count: 4)
        let routes = try Dictionary(uniqueKeysWithValues: requests.enumerated().map {
            index, request in
            (
                request.command.roomID,
                try V2RoomShardRoute(
                    shardID: index.isMultiple(of: 2) ? "rooms-a" : "rooms-b",
                    epoch: 0
                )
            )
        })
        let router = TestRoomRouter(routes: routes)
        let firstStore = RecordingAtomicStore()
        let secondStore = RecordingAtomicStore()
        let routed = try V2RoutedRoomWriteStore(
            router: router,
            stores: ["rooms-a": firstStore, "rooms-b": secondStore],
            physicalStoreKeyByShard: [
                "rooms-a": "postgres-a",
                "rooms-b": "postgres-b",
            ]
        )

        let outcomes = try await routed.acceptAtomically(requests: requests)

        #expect(outcomes.count == requests.count)
        #expect(await router.batchRouteCallCount() == 1)
        #expect(await router.singleRouteCallCount() == 0)
        #expect(await firstStore.batches() == [[
            requests[0].command.clientMessageID,
            requests[2].command.clientMessageID,
        ]])
        #expect(await secondStore.batches() == [[
            requests[1].command.clientMessageID,
            requests[3].command.clientMessageID,
        ]])
    }

    @Test("co-located logical owners preserve each route and retain one atomic append batch")
    func coLocatedOwnersPreserveRoutesAndRetainOneAtomicBatch() async throws {
        let requests = try makeRequests(count: 3)
        let routes = try Dictionary(uniqueKeysWithValues: zip(
            requests.map { $0.command.roomID }, ["rooms-00", "rooms-01", "rooms-02"]
        ).map { roomID, shardID in (roomID, try V2RoomShardRoute(shardID: shardID, epoch: Int64(roomID.uuidValue!.uuidString.suffix(2))!)) })
        let router = TestRoomRouter(routes: routes)
        let store = RecordingAtomicStore()
        let routed = try V2RoutedRoomWriteStore(
            router: router,
            stores: ["rooms-00": store, "rooms-01": store, "rooms-02": store],
            physicalStoreKeyByShard: ["rooms-00": "postgres-a", "rooms-01": "postgres-a", "rooms-02": "postgres-a"]
        )

        let outcomes = try await routed.acceptAtomically(requests: requests)

        #expect(outcomes.count == requests.count)
        #expect(await router.batchRouteCallCount() == 1)
        #expect(await router.singleRouteCallCount() == 0)
        #expect(await store.batches() == [requests.map(\.command.clientMessageID)])
        #expect(await store.capturedRoutes() == requests.map { routes[$0.command.roomID]! })
    }

    @Test("eligibility resolves routes for a single physical owner")
    func eligibilityResolvesRoutesForSinglePhysicalOwner() async throws {
        let requests = try makeRequests(count: 3)
        let routes = try Dictionary(uniqueKeysWithValues: requests.map {
            ($0.command.roomID, try V2RoomShardRoute(shardID: "rooms-00", epoch: 0))
        })
        let router = TestRoomRouter(routes: routes)
        let store = RecordingAtomicStore()
        let routed = try V2RoutedRoomWriteStore(
            router: router,
            stores: ["rooms-00": store],
            physicalStoreKeyByShard: ["rooms-00": "postgres-a"]
        )

        #expect(await routed.atomicBatchEligibility(requests: requests) == [true, true, true])
        #expect(await router.batchRouteCallCount() == 1)
        #expect(await store.eligibilityBatches() == [requests.map(\.command.clientMessageID)])
    }
}

private actor TestRoomRouter: V2RoomShardRouting {
    private let routeMap: [RoomID: V2RoomShardRoute]
    private var singleCalls = 0
    private var batchCalls = 0

    init(routes: [RoomID: V2RoomShardRoute]) { self.routeMap = routes }

    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        singleCalls += 1
        guard let route = routeMap[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return route
    }

    func routes(for roomIDs: [RoomID]) throws -> [RoomID: V2RoomShardRoute] {
        batchCalls += 1
        var resolved: [RoomID: V2RoomShardRoute] = [:]
        for roomID in roomIDs {
            guard let route = routeMap[roomID] else { throw V2RoomShardRouteError.roomNotFound }
            resolved[roomID] = route
        }
        return resolved
    }

    func singleRouteCallCount() -> Int { singleCalls }
    func batchRouteCallCount() -> Int { batchCalls }
}

private actor RecordingAtomicStore: V2OwnerValidatedRoomWriteStore {
    private var atomicBatches: [[ClientMessageID]] = []
    private var receivedRoutes: [V2RoomShardRoute] = []

    func acceptOwnerValidated(request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute) -> V2SendMessageOutcome {
        receivedRoutes.append(ownerRoute)
        return accept(command: request.command, capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)
    }

    func acceptAtomicallyOwnerValidated(requests: [V2OwnerValidatedRoomWriteRequest]) -> [V2SendMessageOutcome] {
        receivedRoutes += requests.map(\.ownerRoute)
        return acceptAtomically(requests: requests.map(\.request))
    }

    func capturedRoutes() -> [V2RoomShardRoute] { receivedRoutes }
    private var eligibilityCalls: [[ClientMessageID]] = []

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) -> V2SendMessageOutcome {
        .rateLimited(retryAfterSeconds: 1)
    }

    func atomicBatchEligibility(requests: [V2RoomWriteRequest]) -> [Bool] {
        eligibilityCalls.append(requests.map(\.command.clientMessageID))
        return Array(repeating: true, count: requests.count)
    }

    func acceptAtomically(requests: [V2RoomWriteRequest]) -> [V2SendMessageOutcome] {
        atomicBatches.append(requests.map(\.command.clientMessageID))
        return requests.map { _ in .rateLimited(retryAfterSeconds: 1) }
    }

    func batches() -> [[ClientMessageID]] { atomicBatches }
    func eligibilityBatches() -> [[ClientMessageID]] { eligibilityCalls }
}

private func makeRequests(count: Int) throws -> [V2RoomWriteRequest] {
    let limits = try RoomCapacityProfile(
        maxEligibleMembers: 8, maxCommandsPerWindow: 100, maxFanoutUnitsPerWindow: 100,
        maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 100, maxEnumerationPageSize: 8,
        maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1
    )
    let profile = try V2CapacityProfile(id: "test", limits: limits)
    let sender = try UserID("00000000-0000-0000-0000-000000000001")
    return try (0 ..< count).map { index in
        let suffix = String(format: "%012d", index + 10)
        let roomID = try RoomID("00000000-0000-0000-0000-\(suffix)")
        let commandID = try ClientMessageID("10000000-0000-0000-0000-\(suffix)")
        let command = try V2SendMessageCommand(
            roomID: roomID, senderUserID: sender, clientMessageID: commandID, text: "test",
            limits: .init(maxUTF8Bytes: 1024)
        )
        return .init(
            command: command, capacityProfile: profile,
            identifiers: try .init(
                messageID: MessageID("20000000-0000-0000-0000-\(suffix)"),
                eventID: EventID("30000000-0000-0000-0000-\(suffix)"),
                planID: FanoutPlanID("40000000-0000-0000-0000-\(suffix)")
            ),
            now: .init(timeIntervalSince1970: 1_750_000_000)
        )
    }
}
