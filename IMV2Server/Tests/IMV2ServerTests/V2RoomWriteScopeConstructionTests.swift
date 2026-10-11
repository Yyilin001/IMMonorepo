@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
import Testing

struct V2RoomWriteScopeConstructionTests {
    @Test("Forward pair construction requires both routes and matching activations")
    func forwardSourceSelection() throws {
        let source = UUID(), target = UUID()
        let route = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
        let host = V2ActorHostIdentity(hostID: try .init("room-writer"), incarnationID: UUID())
        let tokens = try [source, target].map {
            V2RoomActivationToken(roomID: .init(uuid: $0),
                owner: try .init(shardID: "room-a", epoch: 1),
                activationEpoch: try .init(1), host: host)
        }
        let activation = try V2RoomActivationWriteScope(tokens: tokens)
        let pair = try V2RoomWriteOwnerSelection.actorForwardPair(
            activation: activation, routes: [source: route, target: route],
            source: source, target: target)
        #expect(pair.forwardSource == source)
        #expect(pair.routes?[source] == route)
        #expect(pair.routes?[target] == route)
        #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
            try V2RoomWriteOwnerSelection.actorForwardPair(
                activation: activation, routes: [target: route], source: source, target: target)
        }
        #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
            try V2RoomWriteOwnerSelection.actorForwardPair(
                activation: activation,
                routes: [source: try .init(shardID: "room-a", epoch: 2), target: route],
                source: source, target: target)
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

}
