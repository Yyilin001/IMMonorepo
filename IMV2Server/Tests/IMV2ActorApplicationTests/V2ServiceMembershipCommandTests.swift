import Foundation
import IMV2ActorCluster
import Testing
@testable import IMV2ActorApplication

@Suite("Dedicated membership controller deployment")
struct V2ServiceMembershipCommandTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_TEST_MEMBERSHIP_CONTROLLER"] == "1"))
    func generatedControllerAndImmutableRequestBindings() throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        func load(_ name: String) throws -> V2RoomActorApplicationConfiguration {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/" + name + "/configuration.json"))
            let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self, from: bytes)
            return try .init(document: document, hostsRooms: nil, configuredShardIDs: ["rooms-primary"])
        }
        let configuration = try load("membership-controller")
        #expect(configuration.policyPlacement == nil && configuration.hostIdentity == nil)
        #expect(configuration.placementControl.identity == nil)
        let peer = try #require(configuration.realtimePeers.first)
        let membership = try V2ActorServiceMembershipRecord(revision: 1, current: [peer.nodeID], peers: [peer])
        let valid = V2ServiceMembershipCommand(deploymentID: configuration.placementControl.clusterID,
            shardID: "rooms-primary", requestID: UUID(), originRevision: 1, membership: membership)
        try valid.validate(configuration: configuration)
        #expect(throws: V2RoomActorApplicationError.invalidRole) { try valid.validate(configuration: load("account")) }
        for (deployment, shard, origin) in [(UUID(), "rooms-primary", UInt64(1)),
            (configuration.placementControl.clusterID, "other", 1), (configuration.placementControl.clusterID, "rooms-primary", 0)] {
            let invalid = V2ServiceMembershipCommand(deploymentID: deployment, shardID: shard,
                requestID: valid.requestID, originRevision: origin, membership: membership)
            #expect(throws: V2RoomActorApplicationError.invalidRole) { try invalid.validate(configuration: configuration) }
        }
    }
}
