import Crypto
import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Durable service membership transitions")
struct V2ActorServiceMembershipRecordTests {
    @Test func roomRoutesFollowJointMembershipAndPreserveAuthorization() throws {
        let a = V2RealtimeShardDiscoveryPeer(nodeID: "a", serviceID: "a", address: "a.test", port: 7337)
        let b = V2RealtimeShardDiscoveryPeer(nodeID: "b", serviceID: "b", address: "b.test", port: 7337)
        let ra = try V2RoomDiscoveryPeer(hostID: .init(uuid: UUID()), serviceID: .init("a"),
            address: "a.test", port: 7337, accessibleShardIDs: ["rooms"], maximumRooms: 100)
        let rb = try V2RoomDiscoveryPeer(hostID: .init(uuid: UUID()), serviceID: .init("b"),
            address: "b.test", port: 7337, accessibleShardIDs: ["rooms"], maximumRooms: 200)
        let initial = try V2ActorServiceMembershipRecord(revision: 1, current: ["a"], peers: [a], roomPeers: [ra])
        let joint = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["b"], peers: [a,b], roomPeers: [ra,rb])
        try joint.validateSuccessor(of: initial)
        let final = try V2ActorServiceMembershipRecord(revision: 3, current: ["b"], peers: [b], roomPeers: [rb])
        try final.validateSuccessor(of: joint)
        let command = V2ActorPlacementCommand.installServiceMembership(joint)
        #expect(try V2ActorPlacementProtobuf.decodeCommand(V2ActorPlacementProtobuf.encode(command)) == command)
        #expect(throws: (any Error).self) {
            try V2ActorServiceMembershipRecord(revision: 3, current: ["b"], peers: [b], roomPeers: [ra,rb])
        }
        let dropped = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["b"], peers: [a,b], roomPeers: [rb])
        #expect(throws: V2ActorPlacementError.invalidTransition) { try dropped.validateSuccessor(of: initial) }
        let enlarged = try V2RoomDiscoveryPeer(hostID: ra.hostID, serviceID: ra.serviceID,
            address: ra.address, port: ra.port, accessibleShardIDs: ["rooms", "other"], maximumRooms: 200)
        let changed = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["b"], peers: [a,b], roomPeers: [enlarged,rb])
        #expect(throws: V2ActorPlacementError.invalidTransition) { try changed.validateSuccessor(of: initial) }
        var malformed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ra)) as? [String: Any])
        malformed["maximumRooms"] = 0
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2RoomDiscoveryPeer.self, from: JSONSerialization.data(withJSONObject: malformed))
        }
    }

    @Test func roomRouteScopesCannotExceedTrustedHostAuthorization() throws {
        let host = V2ActorHostID(uuid: UUID())
        let key = Curve25519.Signing.PrivateKey()
        let service = try V2ActorServiceID("host")
        let trust = try V2ActorTrustStore(services: [.init(serviceID: service,
            publicKey: key.publicKey.rawRepresentation, permissions: [], hostedIDs: [host], sourceIDs: ["rooms", "other"])])
        let route = try V2RoomDiscoveryPeer(hostID: host, serviceID: service,
            address: "host.test", port: 7337, accessibleShardIDs: ["rooms"], maximumRooms: 100)
        try trust.validateRoomRoster([route], configured: [host: ["rooms"]])
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try trust.validateRoomRoster([route], configured: [host: []])
        }
        // Bootstrap identities need explicit local scope, even if their signed
        // record has source IDs. Only admitted identities use dynamic fallback.
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try trust.validateRoomRoster([route], configured: [:])
        }
        let oversized = try V2RoomDiscoveryPeer(hostID: host, serviceID: service,
            address: "host.test", port: 7337, accessibleShardIDs: ["rooms", "other"], maximumRooms: 100)
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try trust.validateRoomRoster([oversized], configured: [host: ["rooms"]])
        }
    }

    @Test func uncommittedMemberRecordIsInvisible() throws {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let membership = try V2ActorServiceMembershipRecord(revision: 1, current: ["a"],
            peers: [.init(nodeID: "a", serviceID: "a", address: "a.test", port: 7337)])
        let roster: Set<V2ActorHostID> = [host.hostID, .init(uuid: UUID()), .init(uuid: UUID())]
        var state = V2PlacementRaftPersistentState(groupID: initial.clusterID, voterID: host.hostID,
            voters: roster, term: 1, log: [
                try .init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial))),
                try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(
                    .installServiceMembership(membership), expected: initial, requestID: UUID())))], commitIndex: 1)
        var application = V2PlacementRaftApplication(groupID: initial.clusterID)
        try application.apply(state)
        #expect(application.snapshot?.serviceMembership == nil)
        state.commitIndex = 2
        try application.apply(state)
        #expect(application.snapshot?.serviceMembership == membership)
        #expect(application.snapshot?.slots == initial.slots)
    }

    @Test func rejectsSkippingJointAndChangingRetainedEndpoints() throws {
        let a = V2RealtimeShardDiscoveryPeer(nodeID: "a", serviceID: "a", address: "a.test", port: 7337)
        let b = V2RealtimeShardDiscoveryPeer(nodeID: "b", serviceID: "b", address: "b.test", port: 7337)
        let initial = try V2ActorServiceMembershipRecord(revision: 1, current: ["a"], peers: [a])
        let joint = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["b"], peers: [b, a])
        try initial.validateSuccessor(of: nil)
        try joint.validateSuccessor(of: initial)
        #expect(throws: V2ActorPlacementError.invalidTransition) { try joint.validateSuccessor(of: nil) }
        let skipped = try V2ActorServiceMembershipRecord(revision: 2, current: ["b"], peers: [b])
        #expect(throws: V2ActorPlacementError.invalidTransition) { try skipped.validateSuccessor(of: initial) }
        let changed = V2RealtimeShardDiscoveryPeer(nodeID: "a", serviceID: "a", address: "moved.test", port: 7337)
        let moved = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["b"], peers: [changed, b])
        #expect(throws: V2ActorPlacementError.invalidTransition) { try moved.validateSuccessor(of: initial) }
        let final = try V2ActorServiceMembershipRecord(revision: 3, current: ["b"], peers: [b])
        try final.validateSuccessor(of: joint)
        #expect(throws: V2ActorPlacementError.staleRevision) { try joint.validateSuccessor(of: final) }
        let command = V2ActorPlacementCommand.installServiceMembership(joint)
        #expect(try V2ActorPlacementProtobuf.decodeCommand(V2ActorPlacementProtobuf.encode(command)) == command)
        #expect(throws: (any Error).self) {
            try V2ActorServiceMembershipRecord(revision: 1, current: ["a", "a"], peers: [a])
        }
    }
}
