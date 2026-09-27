import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("V2 room actor forwarding coordinator")
struct V2RoomActorForwardingCoordinatorTests {
    @Test func colocatedResourceUsesDurableCopyButSameRoomKeepsPair() async throws {
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), target = RoomID(uuid: UUID())
        let source = try V2ForwardMessageReference(roomID: room, messageID: .init(uuid: UUID()), revision: .init(1))
        let seen = ForwardPairCalls(), checks = Mutex<Int>(0)
        let route = try V2RoomShardRoute(shardID: "same", epoch: 0)
        let coordinator = try V2ActorForwardingCoordinator(
            router: ForwardTestRoutes(values: [room: route, target: route]),
            physicalStoreKeyByShard: ["same": "db"], pair: .init { pair, _ in
                await seen.append(pair)
                return .init(sourceMessageID: pair.source.messageID, targetRoomID: pair.targetRoomID,
                    messageID: .init(uuid: UUID()), roomSequence: 1, errorCode: nil)
            }, crossOwner: ForwardPendingTarget(), requiresImport: { _, _, _, selected, _ in
                #expect(selected == target)
                checks.withLock { $0 += 1 }
                return true
            }, deadline: { .now + .seconds(5) })
        await #expect(throws: V2ForwardPendingError.pending) {
            _ = try await coordinator.forward(actorUserID: actor, command: .init(operationID: .init(uuid: UUID()),
                sources: [source], targetRoomIDs: [room, target]))
        }
        #expect(checks.withLock { $0 } == 1)
        #expect(await seen.values().map(\.targetRoomID) == [room])
    }

    @Test func resourceRoutingFailureNeverFallsBackToSharedReference() async throws {
        let room = RoomID(uuid: UUID()), target = RoomID(uuid: UUID()), seen = ForwardPairCalls()
        let route = try V2RoomShardRoute(shardID: "same", epoch: 0)
        let coordinator = try V2ActorForwardingCoordinator(
            router: ForwardTestRoutes(values: [room: route, target: route]),
            physicalStoreKeyByShard: ["same": "db"], pair: .init { pair, _ in
                await seen.append(pair)
                throw V2ForwardInboxError.corruptPersistenceState
            }, crossOwner: ForwardPendingTarget(), requiresImport: { _, _, _, _, _ in
                throw V2ResourceProviderError.temporarilyUnavailable
            }, deadline: { .now + .seconds(5) })
        await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
            _ = try await coordinator.forward(actorUserID: .init(uuid: UUID()),
                command: .init(operationID: .init(uuid: UUID()), sources: [.init(roomID: room,
                    messageID: .init(uuid: UUID()), revision: .init(1))], targetRoomIDs: [target]))
        }
        #expect(await seen.values().isEmpty)
    }

    @Test func pendingTargetDoesNotCancelSameOwnerSibling() async throws {
        let actor = UserID(uuid: UUID())
        let sourceRoom = RoomID(uuid: UUID())
        let remote = RoomID(uuid: UUID())
        let source = V2ForwardMessageReference(roomID: sourceRoom,
            messageID: MessageID(uuid: UUID()), revision: try .init(1))
        let seen = ForwardPairCalls()
        let routes = ForwardTestRoutes(values: [sourceRoom: try .init(shardID: "owner-a", epoch: 0),
                                                remote: try .init(shardID: "owner-b", epoch: 0)])
        let coordinator = try V2ActorForwardingCoordinator(router: routes,
            physicalStoreKeyByShard: ["owner-a": "db-a", "owner-b": "db-b"],
            pair: .init { pair, _ in
                await seen.append(pair)
                return .init(sourceMessageID: pair.source.messageID,
                    targetRoomID: pair.targetRoomID, messageID: MessageID(uuid: UUID()),
                    roomSequence: 3, errorCode: nil)
            }, crossOwner: ForwardPendingTarget(),
            deadline: { .now + .seconds(5) })
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()),
            sources: [source], targetRoomIDs: [remote, sourceRoom])
        await #expect(throws: V2ForwardPendingError.pending) {
            _ = try await coordinator.forward(actorUserID: actor, command: command)
        }
        let calls = await seen.values()
        #expect(calls.count == 1)
        #expect(calls[0].source.roomID == sourceRoom)
        #expect(calls[0].targetRoomID == sourceRoom)
    }

    @Test func eachPairKeepsSourceThenTargetOrder() async throws {
        let actor = UserID(uuid: UUID())
        let roomA = RoomID(uuid: UUID()), roomB = RoomID(uuid: UUID())
        let sourceA = V2ForwardMessageReference(roomID: roomA,
            messageID: MessageID(uuid: UUID()), revision: try .init(1))
        let sourceB = V2ForwardMessageReference(roomID: roomB,
            messageID: MessageID(uuid: UUID()), revision: try .init(2))
        let seen = ForwardPairCalls()
        let route = try V2RoomShardRoute(shardID: "owner-a", epoch: 0)
        let coordinator = try V2ActorForwardingCoordinator(
            router: ForwardTestRoutes(values: [roomA: route, roomB: route]),
            physicalStoreKeyByShard: ["owner-a": "db-a"],
            pair: .init { pair, _ in
                await seen.append(pair)
                return .init(sourceMessageID: pair.source.messageID,
                    targetRoomID: pair.targetRoomID, messageID: MessageID(uuid: UUID()),
                    roomSequence: 5, errorCode: nil)
            }, crossOwner: ForwardPendingTarget(),
            deadline: { .now + .seconds(5) })
        let results = try await coordinator.forward(actorUserID: actor,
            command: .init(operationID: .init(uuid: UUID()),
                sources: [sourceA, sourceB], targetRoomIDs: [roomB, roomA]))
        #expect(results.count == 4)
        #expect(results.map(\.sourceMessageID) == [sourceA.messageID, sourceA.messageID,
                                                      sourceB.messageID, sourceB.messageID])
        #expect(results.map(\.targetRoomID) == [roomB, roomA, roomB, roomA])
        #expect(await seen.values().count == 4)
    }

    @Test func allPairsShareTheOriginalDeadline() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let sources = try (0..<3).map { _ in
            try V2ForwardMessageReference(roomID: room,
                messageID: MessageID(uuid: UUID()), revision: .init(1))
        }
        let deadlines = ForwardDeadlineCalls()
        let reads = Mutex<Int>(0)
        let coordinator = try V2ActorForwardingCoordinator(
            router: ForwardTestRoutes(values: [room: .init(shardID: "a", epoch: 0)]),
            physicalStoreKeyByShard: ["a": "db"],
            pair: .init { pair, deadline in
                await deadlines.append(deadline)
                return .init(sourceMessageID: pair.source.messageID,
                    targetRoomID: pair.targetRoomID, messageID: MessageID(uuid: UUID()),
                    roomSequence: 1, errorCode: nil)
            }, crossOwner: ForwardPendingTarget(), deadline: {
                reads.withLock { $0 += 1 }
                return .now + .seconds(5)
            })
        _ = try await coordinator.forward(actorUserID: actor,
            command: .init(operationID: .init(uuid: UUID()),
                sources: sources, targetRoomIDs: [room]))
        let values = await deadlines.values()
        #expect(values.count == 3 && values.allSatisfy { $0 == values[0] })
        #expect(reads.withLock { $0 } == 1)
    }
}

private actor ForwardPairCalls {
    private var pairs: [V2ActorForwardPairWire] = []
    func append(_ pair: V2ActorForwardPairWire) { pairs.append(pair) }
    func values() -> [V2ActorForwardPairWire] { pairs }
}

private actor ForwardDeadlineCalls {
    private var deadlines: [ContinuousClock.Instant] = []
    func append(_ value: ContinuousClock.Instant) { deadlines.append(value) }
    func values() -> [ContinuousClock.Instant] { deadlines }
}

private struct ForwardTestRoutes: V2RoomShardRouting {
    let values: [RoomID: V2RoomShardRoute]
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let value = values[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return value
    }
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        values.filter { roomIDs.contains($0.key) }
    }
}

private struct ForwardPendingTarget: V2CrossOwnerForwarding {
    func forward(actor _: UserID, operation _: MessageForwardOperationID,
                 source _: V2ForwardMessageReference, sourceRoute _: V2RoomShardRoute,
                 target _: RoomID, targetRoute _: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        .pending(paused: false)
    }
}
