import IMV2Core
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure
import Testing
@testable import IMV2ActorApplication

@Suite("Room actor deployment configuration rejects absent or invalid trust boundaries")
struct V2RoomActorApplicationConfigurationTests {
    @Test func configurationIsRequired() throws {
        #expect(throws: V2RoomActorApplicationConfigurationError.missingConfiguration) {
            try V2RoomActorApplicationConfiguration(environment: EmptyEnvironment(),
                hostsRooms: true, configuredShardIDs: ["rooms"])
        }
    }

    @Test func roleMismatchFailsBeforeOpeningSecrets() throws {
        let document = V2RoomActorApplicationConfiguration.Document(placementControl: .init(port: 7338, threadPoolSize: 1, localVoterID: nil, storagePaths: [:], voters: []), name: "gateway", address: "localhost",
            port: 7337, threadPoolSize: 1, serviceID: "gateway", hostID: nil,
            signingKeyPath: "/does-not-exist", certificatePath: "/does-not-exist",
            privateKeyPath: "/does-not-exist", trustRootPath: "/does-not-exist", services: [], peers: [], realtimePeers: [])
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) {
            try V2RoomActorApplicationConfiguration(document: document, hostsRooms: true,
                configuredShardIDs: ["rooms"])
        }
    }

    @Test("generated local deployment loads both host and caller identities",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"] != nil))
    func generatedDeployment() throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        for (name, isHost) in [("gateway", true), ("account", false)] {
            let configuration = try V2RoomActorApplicationConfiguration(
                environment: FileEnvironment(path: root + "/" + name + "/configuration.json"),
                hostsRooms: isHost, configuredShardIDs: ["rooms-primary"], batchWaitMilliseconds: 25)
            #expect((configuration.hostIdentity != nil) == isHost)
            #expect(configuration.signer.serviceID.rawValue == name)
            #expect(configuration.discovery.peers.count == 1)
            #expect(configuration.placementControl.roles.count == 3)
            #expect(configuration.placementControl.identity == nil)
            #expect(configuration.placementControl.storagePaths.isEmpty)
            #expect(configuration.hostIdentity?.incarnationID == (isHost ? configuration.placementControl.processIncarnation : nil))
            #expect(configuration.realtimePeers.count == (isHost ? 1 : 2))
            #expect(configuration.realtimePeers.contains { $0.nodeID == name && $0.serviceID == name })
            #expect(configuration.runtime.batchWait.rawValue == 25)
            let derived = try V2RoomActorApplicationConfiguration(
                environment: FileEnvironment(path: root + "/" + name + "/configuration.json"),
                hostsRooms: nil, configuredShardIDs: ["rooms-primary"])
            #expect((derived.hostIdentity != nil) == isHost)
            #expect(derived.serviceShardAccess.isEmpty == !isHost)
            #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) {
                try V2RoomActorApplicationConfiguration(
                    environment: FileEnvironment(path: root + "/" + name + "/configuration.json"),
                    hostsRooms: !isHost, configuredShardIDs: ["rooms-primary"])
            }
            for invalidDelay: Int64 in [0, 26] {
                #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) {
                    try V2RoomActorApplicationConfiguration(
                        environment: FileEnvironment(path: root + "/" + name + "/configuration.json"),
                        hostsRooms: isHost, configuredShardIDs: ["rooms-primary"],
                        batchWaitMilliseconds: invalidDelay)
                }
            }
        }
    }

    @Test("policy placement binds configured peers, endpoints and explicit roles",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"] != nil))
    func policyPlacementTrustBindings() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/gateway/configuration.json"))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let peers = try #require(object["peers"] as? [[String: Any]])
        let hostID = try #require(peers.first?["hostID"] as? String)
        var services = try #require(object["services"] as? [[String: Any]])
        for i in services.indices {
            services[i]["permissions"] = (services[i]["permissions"] as? [String] ?? []) + ["policyMutation", "policyRegistration"]
        }
        object["services"] = services
        object["policyPlacement"] = ["revision": 1, "partitionCount": 16,
            "owners": [["hostID": hostID, "endpoint": "rooms-primary", "partitions": Array(0..<16)]]]
        func load(_ value: [String: Any]) throws -> V2RoomActorApplicationConfiguration {
            let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self,
                from: JSONSerialization.data(withJSONObject: value))
            return try .init(document: document, hostsRooms: true, configuredShardIDs: ["rooms-primary"])
        }
        let prepared = try load(object)
        #expect(prepared.policyPlacement?.partitionCount == 16)
        do {
            _ = try await V2RoomActorApplication.start(configuration: prepared, ownerRouter: UnusedPolicyStartupRouter(), roomDatabases: [:])
            Issue.record("Policy placement started without its authorization services")
        } catch V2RoomActorApplicationError.invalidRole {}
        var missingRole = object
        services[0]["permissions"] = ["userRoomCalls", "roomCoordination", "realtimePublish", "realtimeReceive"]
        missingRole["services"] = services
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(missingRole) }
        var wrongPeer = object
        wrongPeer["policyPlacement"] = ["revision": 1, "partitionCount": 1,
            "owners": [["hostID": UUID().uuidString, "endpoint": "rooms-primary", "partitions": [0]]]]
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(wrongPeer) }
        var wrongEndpoint = object
        wrongEndpoint["policyPlacement"] = ["revision": 1, "partitionCount": 1,
            "owners": [["hostID": hostID, "endpoint": "unconfigured", "partitions": [0]]]]
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(wrongEndpoint) }
    }

    @Test("Control configuration is mandatory and cannot reuse room endpoints or change voter bindings",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"] != nil))
    func fixedControlBoundaries() throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/gateway/configuration.json"))
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        func load(_ value: [String: Any]) throws -> V2RoomActorApplicationConfiguration {
            let doc = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self,
                from: JSONSerialization.data(withJSONObject: value))
            return try .init(document: doc, hostsRooms: true, configuredShardIDs: ["rooms-primary"])
        }
        var missing = original; missing.removeValue(forKey: "placementControl")
        #expect(throws: DecodingError.self) { try load(missing) }
        let originalControl = try #require(original["placementControl"] as? [String: Any])
        var control = originalControl, changed = original
        control["port"] = original["port"]; changed["placementControl"] = control
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(changed) }
        control = originalControl
        var voters = try #require(control["voters"] as? [[String: Any]])
        voters[1]["hostID"] = voters[0]["hostID"]; control["voters"] = voters; changed["placementControl"] = control
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(changed) }
        control = originalControl; control["storagePaths"] = ["rooms-primary": "/tmp/unexpected-voter.pb"]
        changed["placementControl"] = control
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try load(changed) }
    }

    private struct FileEnvironment: V2RuntimeEnvironment {
        let path: String
        func value(for key: String) -> String? {
            key == "IMV2_ROOM_ACTOR_CONFIGURATION_FILE" ? path : nil
        }
    }

    private struct EmptyEnvironment: V2RuntimeEnvironment {
        func value(for key: String) -> String? { nil }
    }
}

private struct UnusedPolicyStartupRouter: V2RoomShardRouting {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { throw V2RoomActorApplicationError.invalidRole }
}
