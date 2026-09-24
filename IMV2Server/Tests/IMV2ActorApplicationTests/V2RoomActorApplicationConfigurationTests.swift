import Foundation
import IMV2Server
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
        let document = V2RoomActorApplicationConfiguration.Document(name: "gateway", address: "localhost",
            port: 7337, threadPoolSize: 1, serviceID: "gateway", hostID: nil,
            signingKeyPath: "/does-not-exist", certificatePath: "/does-not-exist",
            privateKeyPath: "/does-not-exist", trustRootPath: "/does-not-exist", services: [], peers: [])
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
