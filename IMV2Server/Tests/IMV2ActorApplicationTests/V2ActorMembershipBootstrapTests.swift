import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import Testing
@testable import IMV2ActorApplication

@Suite("Application bootstrap uses committed service membership")
struct V2ActorMembershipBootstrapTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"] != nil),
          arguments: ["stable", "joining", "removed", "moved", "unknown"])
    func restoresVersionAndTrustBoundary(mode: String) throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/gateway/configuration.json"))
        var document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self, from: bytes)
        document.serviceMembershipShard = "rooms-primary"
        let configuration = try V2RoomActorApplicationConfiguration(document: document, hostsRooms: true,
            configuredShardIDs: ["rooms-primary"])
        #expect(configuration.serviceMembershipShard == "rooms-primary")
        document.serviceMembershipShard = "missing"
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) {
            try V2RoomActorApplicationConfiguration(document: document, hostsRooms: true, configuredShardIDs: ["rooms-primary"])
        }
        let gateway = try #require(configuration.realtimePeers.first)
        let account = V2RealtimeShardDiscoveryPeer(nodeID: "account", serviceID: "account", address: "localhost", port: 7338)
        let record: V2ActorServiceMembershipRecord
        switch mode {
        case "joining": record = try .init(revision: 8, current: ["account"], next: ["account", gateway.nodeID], peers: [gateway, account])
        case "removed": record = try .init(revision: 9, current: ["account"], peers: [account])
        case "moved": record = try .init(revision: 9, current: [gateway.nodeID], peers: [
            .init(nodeID: gateway.nodeID, serviceID: gateway.serviceID, address: "moved.test", port: gateway.port)])
        case "unknown": record = try .init(revision: 9, current: [gateway.nodeID, "unknown"], peers: [gateway,
            .init(nodeID: "unknown", serviceID: "unknown", address: "unknown.test", port: 7337)])
        default: record = try .init(revision: 9, current: [gateway.nodeID], peers: [gateway])
        }
        if ["moved", "unknown"].contains(mode) {
            #expect(throws: (any Error).self) {
                try V2ActorMembershipBootstrap.qualification(record: record, configuration: configuration)
            }
            return
        }
        let qualification = try V2ActorMembershipBootstrap.qualification(record: record, configuration: configuration)
        #expect(qualification.membership == record.membership)
        if mode == "removed" {
            #expect(qualification.snapshot() == nil)
            #expect(qualification.update(witnesses: ["account": .now + .seconds(10)], membershipRevision: 9) == nil)
        }
        if mode == "joining" {
            #expect(qualification.snapshot() == nil)
            #expect(qualification.update(witnesses: ["account": .now + .seconds(10)], membershipRevision: 1) == nil)
            #expect(qualification.update(witnesses: ["account": .now + .seconds(10)], membershipRevision: 8) != nil)
        }
    }
}
