@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
import Testing

struct V2RoomWriteScopeConstructionTests {
    @Test("Forward owner selection retains its source route and rejects conflicts")
    func forwardSourceSelection() throws {
        let source = UUID(), target = UUID()
        let route = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
        let stale = try V2RoomShardRoute(shardID: "room-a", epoch: 2)
        let targetOnly = try V2RoomWriteOwnerSelection().selectingRoutes([target: route])
        #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
            try targetOnly.selectingForwardSource(source, route: stale)
                .selectingRoutes([target: route])
        }
        let pair = try targetOnly.selectingForwardSource(source, route: route)
        #expect(pair.forwardSource == source)
        #expect(pair.routes?[source] == route)
        #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
            try pair.selectingForwardSource(source, route: stale)
        }
    }

    @Test("Activation can be selected without an owner route")
    func activationWithoutRoute() throws {
        let room = UUID()
        let token = V2RoomActivationToken(
            roomID: .init(uuid: room),
            owner: try .init(shardID: "room-a", epoch: 1),
            activationEpoch: try .init(1),
            host: .init(hostID: try .init("room-writer"), incarnationID: UUID()))
        let activation = try V2RoomActivationWriteScope(tokens: [token])
        let selected = V2RoomWriteOwnerSelection().withActivation(activation)
        #expect(selected.routes == nil)
        #expect(try selected.activation?.token(for: room) == token)
    }

    @Test("Forward scope preserves a same-room operation and verifies route epochs")
    func forwardActivationSelection() throws {
        let room = UUID()
        let token = V2RoomActivationToken(
            roomID: .init(uuid: room),
            owner: try .init(shardID: "room-a", epoch: 1),
            activationEpoch: try .init(1),
            host: .init(hostID: try .init("room-writer"), incarnationID: UUID()))
        let activation = try V2RoomActivationWriteScope(tokens: [token])
        let route = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
        let selected = try V2RoomWriteOwnerSelection.actorForwardPair(
            activation: activation, routes: [room: route], source: room, target: room)
        #expect(selected.forwardSource == room)
        #expect(try selected.activation?.token(for: room) == token)
        #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
            try V2RoomWriteOwnerSelection.actorForwardPair(
                activation: activation,
                routes: [room: try .init(shardID: "room-a", epoch: 2)],
                source: room, target: room)
        }
    }

    @Test("Prepared control state with no grants does not reserve again")
    func emptyPreparedControl() {
        let room = UUID()
        let unresolved = V2RoomWriteControlResolution.unresolved
        let prepared = V2RoomWriteControlResolution.preparedWithoutGrants(roomKinds: [room: "group"])
        #expect(unresolved.needsPreparation)
        #expect(!prepared.needsPreparation)
        #expect(prepared.roomKinds?[room] == "group")
        #expect(prepared.policies?.isEmpty == true)
        #expect(prepared.authorization == nil)
    }
}
