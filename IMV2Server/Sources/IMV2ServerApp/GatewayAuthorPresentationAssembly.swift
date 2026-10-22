import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import FluentKit
import IMV2ActorApplication
import IMV2Server
import IMV2ServerInfrastructure

/// Provider selection stays in the application root. Authorization and runtime
/// ownership below accept only the resource delivery port.
enum GatewayAuthorPresentationAssembly {
    static func build(controlDatabase: any Database, actors: V2RoomActorApplication,
                      delivery: any V2ResourceDelivery) throws -> V2AuthorPresentationRuntime {
        let profiles = V2ResourceProfilePresentationService(controlDatabase: controlDatabase,
            authorization: .init(directory: actors.directory), avatars: .init(delivery: delivery))
        return .init(configuration: try .init(), ingressConfiguration: try .init(), read: { request, identity in
            try await profiles.read(request, actorUserID: identity.userID, deviceID: identity.deviceID)
        }, closeReader: { await profiles.close() })
    }

    /// Signs for the account resource-byte endpoint with the same configured backend registry.
    static func delivery(configuration: V2ResourceRuntimeConfiguration,
                         storage: V2ResourceStorageAssembly,
                         controlDatabase: any Database) async throws -> any V2ResourceDelivery {
        try await V2ResourceStorageReadiness.verify(database: controlDatabase, registry: storage.registry)
        return try V2SignedResourceDelivery(registry: storage.registry, baseURL: configuration.publicBaseURL,
            keyID: "local-v1", keys: ["local-v1": configuration.signingKey])
    }
}
