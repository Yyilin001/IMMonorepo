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

    private struct EmptyEnvironment: V2RuntimeEnvironment {
        func value(for key: String) -> String? { nil }
    }
}
